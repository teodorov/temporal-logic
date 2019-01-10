
import util.classical
import util.predicate
import util.data.option
import util.control.applicative
import util.meta.tactic
import tactic.basic

import tactic

import temporal_logic.basic
import temporal_logic.persistent
import temporal_logic.pair

open predicate

/-
   The auto quotation currently supports two classes of tactics: tactic and smt_tactic.
   To add a new class Tac, we have to
   1) Make sure it is a monad. That is, we have an instance for (monad Tac)
   2) There is a namespace Tac.interactive
   3) There is a definition: Tac.step {α : Type} (t : Tac α) : Tac unit
   4) (Optional) Tac.istep {α : Type} (line0 col0 : nat) (line col : nat) (tac : Tac α) : Tac unit
      Similar to step but it should scope trace messages at the given line/col,
      and ensure that the exception position is after (line0, col0)
   6) There is a definition Tac.save_info (line col : nat) : Tac unit
   7) There is a definition Tac.execute (tac : Tac unit) : tactic unit
   8) There is a definition Tac.execute_with (cfg : config) (tac : Tac unit) : tactic unit
      where config is an arbitrary type.
   TODO(Leo): improve the "recipe" above. It is too ad hoc.
-/

meta def temporal : Type → Type :=
tactic

open format

meta def format.intercalate (x : format) : list format → format :=
format.join ∘ list.intersperse x

meta def unlines : list format → format :=
format.intercalate line

meta instance : monad temporal :=
by { dunfold temporal, apply_instance }

meta instance : monad_fail temporal :=
by { dunfold temporal, apply_instance }

meta instance : alternative temporal :=
by { dunfold temporal, apply_instance }

meta instance andthen_seq : has_andthen (temporal unit) (temporal unit) (temporal unit) :=
by { dunfold temporal, apply_instance }

meta instance andthen_seq_focus : has_andthen (temporal unit) (list (temporal unit)) (temporal unit) :=
by { dunfold temporal, apply_instance }

namespace temporal
open tactic applicative
open interactive
open tactic.interactive (resetI rw_rules rw_rules_t rw_rule get_rule_eqn_lemmas to_expr'
                         unfreezeI solve_by_elim)
open has_to_tactic_format
open functor list (filter)

section expr
open expr
variable {elab : bool}
meta def get_app_args_aux' : list (expr elab) → expr elab → list (expr elab)
| r (app f a) := get_app_args_aux' (a::r) f
| r e         := r

meta def get_app_args' : (expr elab) → list (expr elab) :=
get_app_args_aux' []

end expr

meta def guarded {α β} : list (tactic α × tactic β) → tactic β
 | [] := failed
 | ((x,y) :: xs) :=
do x ← try_core x,
   if x.is_some then
     y
   else guarded xs

meta def check_scope (e : expr) : tactic unit :=
do mmap' (get_local ∘ expr.local_pp_name) e.list_local_consts

meta def type_check_result (msg : format) : tactic unit :=
result >>= type_check <|> fail msg

meta def mk_tmp_app {α} [has_to_pexpr α] (e₀ : expr) (e₁ : α) : temporal expr :=
do t ← infer_type e₀,
   (do e' ← to_expr (to_pexpr e₁), e₀ e' <$ type_check (e₀ e'))
   <|> to_expr ``(p_impl_revert %%e₀ %%e₁)
   <|> to_expr ``(henceforth_deduction %%e₀ %%e₁)
   <|> to_expr ``(p_forall_revert %%e₀ %%e₁)

meta def t_to_expr' : pexpr → temporal expr
| e@(expr.app e₀ e₁) :=
   to_expr e <|>
do e' ← t_to_expr' e₀,
   mk_tmp_app e' e₁
| e := to_expr e

meta def t_to_expr (q : pexpr) : temporal expr :=
do p ← t_to_expr' q <|> to_expr q,
   check_scope p,
   return p

meta def t_to_expr_for_apply (q : pexpr) : temporal expr :=
let aux (n : name) : tactic expr := do
  p ← resolve_name n,
  match p with
  | (expr.const c []) := do r ← mk_const c, save_type_info r q, return r
  | _                 := t_to_expr p
  end
in match q with
| (expr.const c [])          := aux c
| (expr.local_const c _ _ _) := aux c
| _                          := t_to_expr q
end

meta def beta_reduction' (eta := ff) : expr → temporal expr
 | (expr.app e₀ e₁) :=
 do e₁ ← beta_reduction' e₁,
    e₀ ← beta_reduction' e₀,
    head_beta $ expr.app e₀ e₁
 | e := do z ← expr.traverse beta_reduction' e,
           if eta then head_eta z
                  else return z


meta def beta_reduction (e : expr) (eta := ff) : temporal expr :=
instantiate_mvars e >>= beta_reduction' eta

meta def succeeds {α} (tac : temporal α) : temporal bool :=
tt <$ tac <|> pure ff

meta def decl_to_fmt (s : tactic_state) (vs : list expr) : expr × option expr → format
| (t,val) :=
let vs := map s.format_expr vs,
    t := s.format_expr t,
    vs' := format.join $ vs.intersperse " " in
match val with
 | (some val) :=
     format!"{vs'} : {t} := {s.format_expr val}"
 | none := format!"{vs'} : {t}"
end

meta def get_assumptions : temporal (list expr) :=
do `(%%Γ ⊢ _) ← target,
   ls ← local_context,
   mfilter (λ l, succeeds $
    do `(%%Γ' ⊢ %%e) ← infer_type l,
       is_def_eq Γ Γ') ls

meta def asm_stmt (Γ e : expr) : temporal (expr × expr × option expr) :=
do t ← infer_type e,
   val ← get_local_value e,
   `(%%Γ' ⊢ %%p) ← return t | return (e,t,val),
   ( do (e,p,val) <$ is_def_eq Γ Γ' ) <|> return (e,t,val)

def compact {α β : Type*} [decidable_eq β] : list (α × β) → list (list α × β)
 | [] := []
 | ( (x,y) :: xs ) :=
   match compact xs with
    | [] := [ ([x],y) ]
    | ( (x',y') :: ys ) :=
      if y = y' then (x::x', y) :: ys
                else ([x],y) :: (x',y') :: ys
   end

meta def temp_to_fmt (g : expr) : temporal (thunk format) :=
do  set_goals [g],
    `(%%Γ ⊢ %%p) ← target | (λ s _, to_fmt s) <$> read,
    hs ← local_context,
    hs' ← mmap (asm_stmt Γ) hs,
    hs' ← mfilter (λ x : _ × _, bnot <$> succeeds (is_def_eq Γ x.1)) hs',
    s ← read,
    let x := decl_to_fmt s ,
    return $ λ _, format.intercalate line [format.intercalate (","++line) $ mapp (decl_to_fmt s) ∘ compact $ hs',format!"⊢ {s.format_expr p}"]

meta def save_info (p : pos) : temporal unit :=
do cleanup,
   gs  ← get_goals,
   let gs' := gs.pw_filter (≠),
   fmt ← mmap temp_to_fmt gs',
   set_goals gs,
   tactic.save_info_thunk p (λ _,
     let header := if fmt.length > 1 then format!"{fmt.length} goals\n" else "",
         eval : thunk format → format := λ f, f () in
     if fmt.empty
       then "no goals"
       else header ++ format.join ((fmt.map eval).intersperse $ line ++ line))

meta def step {α : Type} (c : temporal α) : temporal unit :=
c >>[tactic] cleanup

meta def istep {α : Type} (line0 col0 line col : nat) (c : temporal α) : temporal unit :=
tactic.istep line0 col0 line col c

meta def show_tags :=
get_goals >>= mmap' (λ g, get_tag g >>= (trace : list name → tactic unit))

meta def uniform_assumptions' (Γ : expr)
: expr → expr → temporal (option (expr × expr))
| h t := do
   t ← head_beta t,
   match t with
    | (expr.pi n bi t' e) :=
      do l ← mk_local' n bi t',
         (some (p,t)) ← uniform_assumptions' (h l) (e.instantiate_var l) | return none,
         let abs := t.lambdas [l],
         let p' := p.lambdas [l],
         p ← some <$> (prod.mk <$> to_expr ``( (p_forall_to_fun %%Γ %%abs).mpr %%p' )
                               <*> to_expr ``( p_forall %%abs )),
         return p
    | `(%%Γ' ⊢ %%p) := (is_def_eq Γ Γ' >> some (h,p) <$ guard (¬ Γ.occurs p))
    | p := none <$ guard (¬ Γ.occurs p) <|> none <$ match_expr ``(persistent %%Γ) p
   end

meta def protect_tags {α : Sort*} (tac : temporal α) : temporal α :=
with_enable_tags $
do t ← get_main_tag,
   tac <* set_main_tag t

/-- `fix_assumptions Γ h` takes assumptions and reformulate it so that its type is
    `Γ ⊢ _`. It replaces `∀ _, Γ ⊢ _` with `Γ ⊢ ∀∀ _, _` and `_ → Γ ⊢ _` with
    `Γ ⊢ _ ⟶ _`.
  -/
meta def fix_assumptions (Γ h : expr) : temporal expr :=
do t ← infer_type h,
   (some r) ← try_core (uniform_assumptions' Γ h t),
   match r with
    | (some (pr,t)) :=
          do  p ← to_expr ``(%%Γ ⊢ %%t),
              protect_tags (
                assertv h.local_pp_name p pr
                <* clear h)
    | none := return h
   end

meta def fix_or_clear_assumption (Γ h : expr) : temporal unit :=
() <$ fix_assumptions Γ h <|> tactic.clear h

meta def semantic_assumption (τ h : expr) : temporal ℕ :=
do `(%%τ' ⊨ _) ← infer_type h | return 0,
   (do is_def_eq τ τ',
       revert h, `[rw ← eq_judgement],
       return 1)
    <|> return 0

meta def sem_to_syntactic : tactic unit :=
do `(%%τ ⊨ _) ← target,
   α ← infer_type τ,
   `[rw ← eq_judgement],
   r ← local_context >>= mfoldl (λ a h, (+) a <$> semantic_assumption τ h) 0,
   tactic.interactive.generalize none () (``(↑(eq %%τ) : pred' %%α), `Γ),
   intron r

meta def execute (c : temporal unit) : tactic unit :=
do intros,
   t ← target,
   t' ← whnf t,
   match t' with
     | `(⊩ _) := () <$ tactic.intro `Γ
     | `(_ ⟹ _) := () <$ tactic.intro `Γ
     | `(∀ Γ : pred' _, Γ ⊢ _) := () <$ tactic.intro `Γ
     | `(%%Γ ⊢ _) := local_context >>= mmap' (fix_or_clear_assumption Γ)
     | _ := to_expr ``(⊩ _) >>= tactic.change >> () <$ tactic.intro `Γ
          <|> refine ``(@id (_ ⊨ _) _) >> sem_to_syntactic
          <|> fail "expecting a goal of the form `_ ⊢ _` or `⊩ _ `"
   end,
   target >>= whnf >>= unsafe_change,
   c

meta def revert (e : expr) : tactic unit :=
do `(%%Γ ⊢ _) ← target >>= instantiate_mvars,
   t ← infer_type e,
   match t with
    | `(%%Γ' ⊢ _) :=
      do ppΓ ← pp Γ, ppΓ' ← pp Γ',
         is_def_eq Γ Γ' <|> fail format!"{ppΓ'} does not match {ppΓ'}",
         tactic.revert e, applyc `predicate.p_impl_revert
    | _ := tactic.revert e >> refine ``((p_forall_to_fun %%Γ _).mp _)
   end

section
open tactic.interactive interactive.types
meta def interactive.strengthening (tac : itactic) : temporal unit :=
do lmms ← attribute.get_instances `strengthening,
   `(%%Γ ⊢ _) ← target,
   p ← infer_type Γ >>= mk_meta_var,
   lmms.any_of $ λ l, do
     r ← tactic.mk_app l [p,Γ],
     tactic.refine ``(p_impl_revert %%r _ ),
     tac

meta def interactive.apply' (q : parse texpr) : temporal unit :=
do l ← t_to_expr_for_apply q,
   () <$ tactic.apply l <|> interactive.strengthening (() <$ tactic.apply l)
                        <|> () <$ tactic.apply l -- we try `tactic.apply l` again
                                                 -- knowing that if we go back to
                                                 -- it, it will fail and we'll have
                                                 -- a proper error message

end

meta def split : temporal unit :=
do `(%%Γ ⊢ %%p ⋀ %%q) ← target,
   interactive.apply ``(p_and_intro %%p %%q %%Γ _ _)

meta def consequent (e : expr) : temporal expr :=
do `(_ ⊢ %%p) ← infer_type e,
   return p

lemma to_antecendent (xs : list (cpred))
  (H : list_persistent xs)
  (p : cpred)
  (h : ◻ xs.foldr (⋀) True ⊢ p)
: ∀ Γ, with_h_asms Γ xs p :=
begin
  intro,
  replace h := λ h', judgement_trans Γ _ _ h' h,
  induction H with x xs,
  { simp at h, simp [with_h_asms,h] with tl_simp, },
  { simp at h, simp_intros [with_h_asms], resetI,
    apply H_ih , intros,
    apply h,
    rw henceforth_and,
    simp [is_persistent],
    begin [temporal]
      split,
      assumption,
      assumption,
    end }
end

inductive entails_all {β} (Γ : pred' β) : list (pred' β) → Prop
 | nil : entails_all []
 | cons (x : pred' β) (xs : list $ pred' β)
   : Γ ⊢ x → entails_all xs →
     entails_all (x :: xs)

lemma entails_all_subst_left {β}
  (p q : pred' β)
  (rs : list $ pred' β)
  (h : p ⟹ q)
  (h' : entails_all q rs)
: entails_all p rs :=
begin
  induction h'
  ; constructor,
  { revert h'_a,
    apply revert_p_imp' h },
  { assumption, }
end

lemma to_antecendent' (xs : list (cpred)) (p : cpred)
  (ps : list_persistent xs)
  (h : ∀ Γ [persistent Γ], with_h_asms Γ xs p)
: ∀ Γ, with_h_asms Γ xs p :=
begin
  apply to_antecendent _ ps,
  have : entails_all (◻list.foldr p_and True xs) xs,
  { clear h ps,
    induction xs with x xs ; constructor,
    { apply indirect_judgement,
      simp_intros Γ h [henceforth_and],
      apply henceforth_str x Γ h.left, },
    { revert xs_ih, apply entails_all_subst_left,
      simp [henceforth_and] } },
  specialize h (◻list.foldr p_and True xs),
  revert this h, generalize : ◻list.foldr p_and True xs = Γ,
  intros h' h,
  induction ps with x xs,
  { simp [with_h_asms] at h,
    apply h },
  { apply_assumption ; cases h', assumption,
    simp [with_h_asms] at h,
    solve_by_elim, }
end

open tactic tactic.interactive (unfold_coes unfold itactic assert_or_rule)
open interactive interactive.types lean lean.parser
open applicative (mmap₂ lift₂)
open functor
local postfix `?`:9001 := optional
section persistently

meta def is_henceforth (e : expr) : temporal bool :=
do `(_ ⊢ %%t) ← infer_type e | return tt,
   succeeds $
     to_expr ``(persistent %%t) >>= mk_instance

private meta def mk_type_list (Γ pred_t : expr)  : list expr → temporal (expr × expr)
 | [] := do
   lift₂ prod.mk (to_expr ``(@list.nil cpred))
                 (to_expr ``(temporal.list_persistent.nil_persistent))
 | (x :: xs) :=
   do (es,is) ← mk_type_list xs,
      v  ← mk_meta_var pred_t,
      `(_ ⊢ %%c) ← infer_type x, c' ← pp c,
      ls ← to_expr ``(list.cons %%c %%es),
      inst₀ ← to_expr ``(persistent %%c) >>= mk_instance,
      inst ← tactic.mk_mapp `temporal.list_persistent.cons_persistent [c,es,inst₀,is],
      return (ls,inst)

meta def is_context_persistent : temporal bool :=
do `(%%Γ ⊢ _) ← target | return ff,
   (tt <$ (to_expr ``(persistent %%Γ) >>= mk_instance)) <|>
     return ff
open list
meta def create_persistent_context : temporal unit :=
do b ← is_context_persistent,
   when (¬ b) $ do
     asms ← get_assumptions,
     `(%%Γ ⊢ %%p) ← target >>= instantiate_mvars,
     pred_t ← infer_type Γ,
     Γ ← get_local Γ.local_pp_name,
     (asms',inst) ← mk_type_list Γ pred_t asms,
     r ← tactic.revert_lst (Γ :: asms : list _).reverse,
     guard (r = asms.length + 1) <|> fail format!"wrong use of context {Γ}",
     ts ← mmap consequent asms,
     hnm ← mk_fresh_name,
     h ← to_expr  ``(@to_antecendent' %%asms' %%p %%inst) >>= note hnm none,
     tactic.interactive.simp none tt [simp_arg_type.expr ``(temporal.with_h_asms)] [] (loc.ns [hnm]),
     h ← get_local hnm,
     refine ``(%%h _),
     -- -- `[simp only [temporal.with_h_asms]],
     intro_lst $ Γ.local_pp_name :: `_ :: asms.map expr.local_pp_name,
     resetI,
     get_local hnm >>= tactic.clear

meta def interactive.persistent (excp : parse without_ident_list) : temporal unit :=
do b ← is_context_persistent,
   when (¬ b) $ do
     hs  ← get_assumptions,
     hs' ← hs.mfilter (map bnot ∘ is_henceforth),
     excp' ← mmap get_local excp,
     mmap' tactic.clear (hs'.diff excp'),
     when excp.empty
       create_persistent_context

meta def persistently (tac : itactic) : temporal unit :=
focus1 $
do create_persistent_context,
      -- calling tac
   x ← focus1 tac,
      -- restore context to Γ
   done <|> (do
     to_expr ```(_ ⊢ _) >>= change)
   <|> (do
     to_expr ```(⊩ _) >>= change,
     `(⊩ %%q) ← target,
     () <$ intro `Γ)
end persistently

section lemmas
open list

lemma judgement_congr {Γ p q : cpred}
  (h : Γ ⊢ p ≡ q)
: Γ ⊢ p = Γ ⊢ q :=
by { apply iff.to_eq, split ; intro h' ;
     lifted_pred using h h' ; cc }

def with_asms {β} (Γ : pred' β) : Π (xs : list (string × pred' β)) (x : pred' β), Prop
 | [] x := Γ ⊢ x
 | ((h,x) :: xs) y := Γ ⊢ x → with_asms xs y

def tl_seq {β} (xs : list (string × pred' β)) (x : pred' β) : Prop :=
∀ Γ, with_asms Γ xs x

lemma p_forall_intro_asms_aux {β t} (ps : list (string × pred' β))
  (φ : pred' β) (q : t → pred' β)
  (h : ∀ x Γ, Γ ⊢ φ → with_asms Γ ps (q x))
  (Γ : pred' β)
  (h' : Γ ⊢ φ )
: with_asms Γ ps (p_forall q) :=
begin
  induction ps generalizing φ,
  case list.nil
  { simp [with_asms] at h ⊢,
    rw p_forall_to_fun,
    introv, apply h _ , exact h', },
  case list.cons : p ps
  { cases p with n p,
    simp [with_asms] at h ⊢,
    intro hp,
    have h_and := (p_and_intro φ p Γ) h' hp,
    revert h_and,
    apply ps_ih,
    intros, apply_assumption,
    apply p_and_elim_left φ p Γ_1 a,
    apply p_and_elim_right φ p Γ_1 a,  }
end

lemma p_forall_intro_asms {t β} (ps : list (string × pred' β)) (q : t → pred' β)
  (h : ∀ x, tl_seq ps (q x))
: tl_seq ps (p_forall q) :=
begin
  intro,
  apply p_forall_intro_asms_aux _ True,
  { intros, apply h },
  simp
end

lemma p_imp_intro_asms_aux {β} (ps : list (string × pred' β))
  (φ q r : pred' β) (n : string)
  (h : ∀ Γ, Γ ⊢ φ → with_asms Γ (ps ++ [(n,q)]) r)
  (Γ : pred' β)
  (h' : Γ ⊢ φ )
: with_asms Γ ps (q ⟶ r) :=
begin
  induction ps generalizing φ,
  case list.nil
  { simp [with_asms] at h ⊢,
    apply p_imp_intro _,
    { introv h₀, apply h _ , exact h₀, },
    solve_by_elim, },
  case list.cons : p ps
  { cases p with n p,
    simp [with_asms] at h ⊢,
    intro hp,
    have h_and := (p_and_intro φ p Γ) h' hp,
    revert h_and,
    apply ps_ih,
    intros, apply_assumption,
    apply p_and_elim_left φ p Γ_1 a,
    apply p_and_elim_right φ p Γ_1 a,  }
end

lemma p_imp_intro_asms {β} (ps : list (string × pred' β))
  (q r : pred' β) (n : string)
  (h : tl_seq (ps ++ [(n,q)]) r)
: tl_seq ps (q ⟶ r) :=
begin
  intro, apply p_imp_intro_asms_aux _ True,
  { intros, apply h },
  simp
end

-- lemma canonical_sequent {β} (Γ p : pred' β)
-- : Γ ⊢ p ↔ (∀ Γ', Γ' ⊢ Γ → Γ' ⊢ p) :=
-- begin
--   split ; intro,
--   { intros, transitivity ; assumption },
--   apply_assumption, refl
-- end

end lemmas

private meta def mk_type_list : list expr → temporal expr
 | [] := to_expr ``(list.nil)
 | (x :: xs) :=
   do es ← mk_type_list xs,
      `(_ ⊢ %%t) ← infer_type x,
      let n := x.local_pp_name.to_string,
      to_expr ``(list.cons (%%(reflect n), %%t) %%es)
open list (cons)

private meta def parse_list : expr → temporal (list (name × expr))
 | `([]) := pure []
 | `( list.cons (%%n,%%e) %%es ) :=
 do n' ← eval_expr _ n,
    (::) (mk_simple_name n',e) <$> parse_list es
 | _ := pure []

private meta def enter_list_state : temporal (expr × list expr × expr) :=
do `(%%Γ ⊢ %%p) ← target,
   ls ← get_assumptions,
   ls' ← mk_type_list ls,
   r ← revert_lst (Γ :: ls : list _).reverse,
   let k := ls.length + 1,
   guard (r = k)
         <|> fail format!"wrong use of context {Γ}: {r} ≠ {k}",
   to_expr ``(tl_seq %%ls' %%p) >>= unsafe_change,
   return (Γ, ls, ls')

private meta def exit_list_state : temporal (list expr) :=
do `(tl_seq %%ps %%g) ← target | return [],
   tactic.interactive.unfold
        [ `has_append.append
        , `list.append] (loc.ns [none]),
   `(tl_seq %%ps %%g) ← target,
   ps' ← parse_list ps,
   tactic.interactive.unfold
        [ `temporal.tl_seq
        , `temporal.with_asms ] (loc.ns [none]),
   tactic.intro_lst (`Γ :: ps'.map prod.fst)

private meta def within_list_state {α} (tac : expr → temporal α) : temporal α :=
do (Γ,ls,ls') ← enter_list_state,
   tac ls' <* do
      tactic.interactive.unfold
        [ `temporal.with_asms
        , `temporal.tl_seq
        , `has_append.append
        , `list.append] (loc.ns [none]),
      tactic.intro_lst ((Γ :: ls : list _).map expr.local_pp_name)

meta def intro_aux (n : option name) : temporal (expr ⊕ name) :=
do ( to_expr ``(tl_seq _ (_ ⟶ _)) >>= change
       <|> to_expr ``(tl_seq _ (p_forall _)) >>= change ),
   `(tl_seq %%ps %%g) ← target >>= instantiate_mvars,
   match g with
    | `(%%p ⟶ %%q)  :=
      do let h := n.get_or_else `_,
         tactic.refine ``(p_imp_intro_asms %%ps %%p %%q %%(reflect h.to_string) _),
         return $ sum.inr h
    | `(p_forall %%P) :=
      do let h := n.get_or_else `_,
         tactic.refine ``(p_forall_intro_asms %%ps %%P _),
         x ← intro h,
         P' ← head_beta (P x),
         to_expr ``(tl_seq %%ps %%P') >>= unsafe_change ,
         return $ sum.inl x
    | _ := fail "expecting `_ ⟶ _` or `∀∀ _, _`"
   end

def cons_opt {α β} : α ⊕ β → list α × list β → list α × list β
 | (sum.inr y) (xs,ys) := (xs,    y::ys)
 | (sum.inl x) (xs,ys) := (x::xs, ys   )

meta def intro_lst : option (list name) → temporal (list expr × list name)
 | none := (cons_opt <$> intro_aux none <*> intro_lst none) <|> pure ([],[])
 | (some []) := return ([],[])
 | (some (x::xs)) := cons_opt <$> intro_aux (some x) <*> intro_lst (some xs)

meta def get_one_name : option (list name) → option (name × option (list name))
 | none := some (`_, none)
 | (some []) := none
 | (some (x::xs)) := some (x, some xs)

open list (hiding map)

meta def intros : option (list name) → temporal (list expr)
| ns :=
do some (n,ns') ← pure (get_one_name ns) | return [],
   mcond (succeeds $ to_expr ``(_ ⊢ _ ⟶ _) >>= change <|>
                     to_expr ``(_ ⊢ p_forall _) >>= change)
   (do g ← target,
       match g with
        | `(%%Γ ⊢ %%p ⟶ %%q)  := do
          try (to_expr ``(persistent %%Γ) >>= mk_instance >>= clear),
          (es,ls') ← within_list_state (λ _, intro_lst ns),
          (++) es <$> tactic.intro_lst ls'
        | `(%%Γ ⊢ p_forall (λ _, %%P)) := do
          refine ``((p_forall_to_fun %%Γ (λ _, %%P)).mpr _),
          n ← tactic.intro n,
          to_expr ``(%%Γ ⊢ %%(P.instantiate_var n)) >>= change,
          cons n <$> intros ns'
        | _ := fail "expecting `_ ⟶ _` or `∀∀ _, _`"
       end)
   (return [])

meta def intro1 (n : option name) : temporal expr :=
do to_expr ``(_ ⊢ _ ⟶ _) >>= change <|>
      to_expr ``(_ ⊢ p_forall _) >>= change <|>
      fail "expecting `_ ⟶ _` or `∀∀ _, _`",
   g ← target,
   match g with
    | `(%%Γ ⊢ %%p ⟶ %%q)  := do
      try (to_expr ``(persistent %%Γ) >>= mk_instance >>= clear),
      let h := n.get_or_else `_,
      within_list_state (λ ps, tactic.refine ``(p_imp_intro_asms %%ps %%p %%q %%(reflect h.to_string) _)),
      intro h
    | `(%%Γ ⊢ p_forall (λ _, %%P)) := do
      refine ``((p_forall_to_fun %%Γ (λ _, %%P)).mpr _),
      n ← tactic.intro $ n.get_or_else `_,
      n <$ (to_expr ``(%%Γ ⊢ %%(P.instantiate_var n)) >>= change)
    | _ := fail "expecting `_ ⟶ _` or `∀∀ _, _`"
   end

/-- Introduces new hypotheses with forward dependencies -/
meta def intros_dep : tactic (list expr) :=
do g ← target | return [],
   match g with
    | `(_ ⊢ p_forall _) := lift₂ (::) (intro1 none) intros_dep
    | `(tl_seq %%ps (p_forall %%P)) :=
      do tactic.refine ``(p_forall_intro_asms %%ps %%P _),
         x ← intro  P.binding_name,
         P' ← head_beta (P x),
         to_expr ``(tl_seq %%ps %%P') >>= unsafe_change ,
         cons x <$> intros_dep
    | _ := return []
   end

@[user_attribute]
meta def lifted_congr_attr : user_attribute :=
{ name := `lifted_congr
, descr := "congruence lemmas for temporal logic" }

@[user_attribute]
meta def timeless_congr_attr : user_attribute :=
{ name := `timeless_congr
, descr := "congruence lemmas for temporal logic" }

meta def apply_lifted_congr : tactic unit :=
do xs ← attribute.get_instances `lifted_congr,
   xs.any_of (λ thm, do l ← resolve_name thm >>= to_expr, apply l),
   return ()

meta def apply_timeless_congr : tactic unit :=
do xs ← attribute.get_instances `timeless_congr,
   xs.any_of (λ thm, do l ← resolve_name thm >>= to_expr, () <$ apply l) <|> apply_lifted_congr

meta def force (p : pexpr) (e : expr) : tactic expr :=
do p' ← to_expr p,
   unify e p',
   instantiate_mvars p' <* cleanup

meta def app_ctx_aux (g : expr → expr)
: list (expr → expr) → list expr → expr → list ( (expr → expr) × expr )
| r₀ r₁ (expr.app f a) := app_ctx_aux ((λ e, g $ f.mk_app (e :: r₁)) :: r₀) (a :: r₁) f
| r₀ r₁ e         := list.zip r₀ r₁

meta def app_ctx (g : expr → expr)
: expr → list ( (expr → expr) × expr ) :=
app_ctx_aux g [] []

meta def match_context_core : pattern → list ((expr → expr) × expr) → tactic (expr → expr)
| p []      := failed
| p ((f,e)::es) :=
  f <$ match_pattern p e
  <|>
  match_context_core p es
  <|>
  if e.is_app
  then match_context_core p (app_ctx f e)
  else failed

meta def match_context (p : pexpr) (e : expr) : tactic (expr → expr) :=
do new_p ← pexpr_to_pattern p,
   match_context_core new_p [(id,e)]

lemma v_eq_symm_h {α} {Γ : cpred} {v₀ v₁ : tvar α}
  (h : Γ ⊢ ◻(v₁ ≃ v₀))
: Γ ⊢ ◻(v₀ ≃ v₁) :=
begin
  revert h, apply p_impl_revert,
  revert Γ, change (_ ⟹ _),
  mono,
  lifted_pred, intro h, rw h
end

meta def temporal_eq_proof (Γ h' x' y' t : expr) (hence : bool) (cfg : rewrite_cfg := {})
: tactic (expr × expr × list expr) :=
do let (x,y) := if cfg.symm then (y',x')
                            else (x',y'),
   err ← pp x,
   ctx ← match_context (to_pexpr x) t <|> fail format!"no instance of {err} found",
   let t' := ctx y,
   p ← to_expr ``(%%Γ ⊢ %%t ≃ %%t'),
   ((),prf) ← solve_aux p (do
   if hence then do
     h ← if cfg.symm then to_expr ``(v_eq_symm_h %%h')
                     else return h',
     h' ← mk_fresh_name,
     note h' none h,
     interactive.persistent [],
     h ← get_local h',
     `(%%Γ ⊢ _) ← target,
     rule ← to_expr ``(predicate.p_impl_revert (henceforth_str _ %%Γ) %%h) <|> pure h,
     repeat (() <$ apply rule <|> refine ``(v_eq_refl _ _) <|> apply_timeless_congr),
     all_goals $
       exact rule,
     return ()
   else do
     h ← if cfg.symm then to_expr ``(v_eq_symm %%h')
                     else return h',
     repeat (() <$ apply h <|> refine ``(v_eq_refl _ _) <|> apply_lifted_congr),
     done),
   prf' ← to_expr ``(judgement_congr %%prf),
   new_t ← to_expr ``(%%Γ ⊢ %%t'),
   return (new_t,prf',[])

meta def tmp_head : expr → temporal expr | e :=
do t ← infer_type e >>= whnf,
   match t with
     | (expr.pi v bi e₀ e₁) :=
       do v ← mk_meta_var e₀,
          tmp_head (e v)
     | `(_ ⊢ _) :=
       do v ← mk_mvar,
          t_to_expr ``(%%e %%v) >>= tmp_head <|> return e
     | _ := return e
   end

-- this is to justify using `whnf` before pattern matching when dealing w
-- with sequents
run_cmd do
v₀ ← mk_local_def `v `(cpred),
e ← to_expr ``(%%v₀ ⊢ %%v₀ ⟶ %%v₀),
e' ← whnf e,
guard (e' = e) <|> fail "_ ⊢ _ ⟶ _ does not reduce to itself"

/--
 Must distinguish between three cases on the shape of assumptions:
 h : Γ ⊢ ◽(x ≡ y)
 h : x = y
 h : x ↔ y

 two cases on the shape of target:
 e: f x
 e: Γ ⊢ f x

 two cases on the shape of target:
 h : Γ ⊢ ◽(x ≡ y) → Γ ⊢ f x = f y

 h : Γ ⊢ ◽(x ≡ y) → Γ ⊢ f x = Γ ⊢ f y
 h : Γ ⊢ ◽(x ≡ y) → Γ ⊢ f x ≡ f y
 h : Γ ⊢ ◽(x ≡ y) ⟶ f x ≡ f y
 h : ⊩ ◽(x ≡ y) ⟶ f x ≡ f y
 -/
meta def rewrite_tmp (Γ h : expr) (e : expr) (cfg : rewrite_cfg := {}) : tactic (expr × expr × list expr) :=
do e ← instantiate_mvars e >>= whnf,
   match e with
    | e'@`(%%Γt ⊢ %%e) :=
    do h ← tmp_head h,
       ht ← infer_type h >>= whnf,
       match ht with
         | `(%%Γr ⊢ ◻%%p) :=
           do `(%%x ≃ %%y) ← force ``(_ ≃ _) p,
              temporal_eq_proof Γ h x y e tt cfg
         | `(%%Γr ⊢ %%p) :=
           do `(%%x ≃ %%y) ← force ``(_ ≃ _) p,
              b ← try_core $ to_expr ``(persistent %%Γr) >>= mk_instance,
              temporal_eq_proof Γ h x y e b.is_some cfg
         | _ :=
           do (new_t, prf, metas) ← rewrite_core h e cfg,
              prf' ← to_expr ``(congr_arg (judgement %%Γt) %%prf),
              new_t' ← to_expr ``(judgement %%Γt %%new_t),
              try_apply_opt_auto_param cfg.to_apply_cfg metas,
              (new_t', prf', metas) <$ is_def_eq Γ Γt <|> pure (new_t,prf,metas)
       end
     | _ := do
          (new_t, prf, metas) ← rewrite_core h e cfg,
          try_apply_opt_auto_param cfg.to_apply_cfg metas,
          return (new_t, prf, metas)
   end

meta def rewrite_target (Γ h : expr) (cfg : rewrite_cfg := {}) : tactic unit :=
do t ← target,
   (new_t, prf, _) ← rewrite_tmp Γ h t cfg,
   e ← to_expr ``(%%t = %%new_t),
   replace_target new_t prf

meta def rewrite_hyp (Γ h : expr) (hyp : expr) (cfg : rewrite_cfg := {}) : tactic expr :=
do hyp_type ← infer_type hyp,
   (new_hyp_type, prf, _) ← rewrite_tmp Γ h hyp_type cfg,
   replace_hyp hyp new_hyp_type prf

meta def rw_goal (Γ : expr) (cfg : rewrite_cfg) (rs : list rw_rule) : temporal unit :=
rs.mmap' $ λ r, do
 save_info r.pos,
 eq_lemmas ← get_rule_eqn_lemmas r,
 orelse'
   (do e ← to_expr' r.rule, rewrite_target Γ e {symm := r.symm, ..cfg})
   (eq_lemmas.mfirst $ λ n, do e ← mk_const n, rewrite_target Γ e {symm := r.symm, ..cfg})
   (eq_lemmas.empty)

private meta def uses_hyp (e : expr) (h : expr) : bool :=
e.fold ff $ λ t _ r, r || to_bool (t = h)

meta def rw_hyp (Γ : expr) (cfg : rewrite_cfg) : list rw_rule → expr → temporal unit
| []      hyp := skip
| (r::rs) hyp := do
  save_info r.pos,
  eq_lemmas ← get_rule_eqn_lemmas r,
  orelse'
    (do e ← to_expr' r.rule,
        when (not (uses_hyp e hyp)) $
          rewrite_hyp Γ e hyp {symm := r.symm, ..cfg} >>= rw_hyp rs)
    (eq_lemmas.mfirst $ λ n, do e ← mk_const n, rewrite_hyp Γ e hyp {symm := r.symm, ..cfg} >>= rw_hyp rs)
    (eq_lemmas.empty)

meta def rewrite (rs : rw_rules_t) (loca : loc) (cfg : rewrite_cfg) : temporal unit :=
do `(%%Γ ⊢ _) ← target,
   match loca with
   | loc.wildcard := loca.try_apply (rw_hyp Γ cfg rs.rules) (rw_goal Γ cfg rs.rules)
   | _            := loca.apply (rw_hyp Γ cfg rs.rules) (rw_goal Γ cfg rs.rules)
   end,
   try (reflexivity reducible : temporal _),
   (returnopt rs.end_pos >>= save_info <|> skip)

meta def solve1 : temporal unit → temporal unit :=
tactic.interactive.solve1

protected meta def note (h : name) : option expr → expr → temporal expr
 | none  pr :=
do p ← infer_type pr >>= beta_reduction,
   assertv h p pr
 | (some p)  pr := assertv h p pr

/-- bind the initial value of state-dependent expression
    `e` to global (through time) name `n`
  -/
meta def bind_name (e : expr) (n h : name) : temporal expr :=
do refine ``(one_point_elim _ _ %%e _),
   x ← tactic.intro n,
   temporal.intros (some [h]),
   return x

meta def existsi (e : expr) (id : name) : temporal unit :=
do `(%%Γ ⊢ ∃∃ _ : %%t, %%intl) ← target,
   infer_type Γ >>= match_expr ``(cpred),
   let r := e.get_app_fn,
   let v := if r.is_constant
            then update_name (λ s, s ++ "₀") (strip_prefix r.const_name)
            else if r.is_local_constant
            then update_name (λ s, s ++ "₀") r.local_pp_name
            else `v₀,
   t' ← infer_type e,
   w ← (match_expr ``(tvar %%t) t' >> (bind_name e v id) <|> return e),
   refine ``(p_exists_to_fun %%w _)

meta def specialized_apply (t : expr) : expr → temporal unit
 | e :=
do t' ← infer_type e,
   type_check e,
   if sizeof t' < sizeof t then () <$ tactic.apply e
   else
     () <$ tactic.apply e <|>
   do
     v ← mk_mvar,
     e' ← mk_tmp_app e v,
     specialized_apply e'

meta def apply (e : expr) : temporal unit :=
do g :: gs ← get_goals,
   t ← target,
   specialized_apply t e
         <|> interactive.strengthening (specialized_apply t e)
         <|> () <$ tactic.apply e,    -- we try `tactic.apply l` again
                                      -- knowing that if we go back to
                                      -- it, it will fail and we'll have
                                      -- a proper error message
   gs' ← get_goals, set_goals gs',
   all_goals (try (execute (pure ()))),
   gs' ← get_goals, set_goals (gs' ++ gs)

namespace interactive
open lean.parser interactive interactive.types lean
open expr -- tactic.interactive (rcases_parse rcases_parse.invert)
local postfix `?`:9001 := optional
local postfix *:9001 := many

precedence `[|`:1024
precedence `|]`:0

meta def abstract_names_p (f : name → option ℕ) : ℕ → pexpr → pexpr
 | k e@(expr.local_const _ n _ _) := option.cases_on (f n) e (λ i, expr.var $ i + k)
 | k e@(expr.const n _) := option.cases_on (f n) e expr.var
 | k e@(var n)  := e
 | k e@(sort l) := e
 | k e@(mvar n m t)   := e
 | k (app e₀ e₁) := app (abstract_names_p k e₀) (abstract_names_p k e₁)
 | k (lam n bi e t) := lam n bi (abstract_names_p k e) (abstract_names_p (k+1) t)
 | k (pi n bi e t) := pi n bi (abstract_names_p k e) (abstract_names_p (k+1) t)
 | k (elet n g e b) := elet n (abstract_names_p k g) (abstract_names_p k e) (abstract_names_p (k+1) b)
 | k (macro d args) := macro d $ args.map (abstract_names_p k)

meta def var_type : pexpr → pexpr
 | (app _ t) := t
 | t := t

meta def lambdas_p_aux : list pexpr → pexpr → pexpr
 | (local_const _ n bi t :: ts) e := lambdas_p_aux ts $ lam n bi (var_type t) e
 | _ e := e

def index_of {α} [decidable_eq α] (xs : list α) (x : α) : option ℕ :=
let r := list.index_of x xs in
if r < xs.length then r
                 else none

meta def lambdas_p (vs : list pexpr) (e : pexpr) : pexpr :=
lambdas_p_aux vs (abstract_names_p (index_of (vs.map expr.local_pp_name)) 0 e)

meta def mk_app_p : pexpr → list pexpr → pexpr
 | e (e' :: es) := mk_app_p ``(var_seq %%e %%e') es
 | e [] := e

@[user_notation]
meta def scoped_var (_ : parse $ tk "[|")
  (ls : parse $ ident* <* tk ",")
  (e : parse  $ texpr  <* tk "|]") : lean.parser pexpr :=
do vs ← ls.mmap (λ pp_n, do (e,_) ← with_input texpr pp_n.to_string,
                            return e ),
   let r := mk_app_p ``( ⟪ ℕ, %%(lambdas_p vs.reverse e) ⟫ ) vs,
   return r

meta def skip : temporal unit :=
tactic.skip

meta def done : temporal unit :=
tactic.done

meta def itactic : Type :=
temporal unit

meta def timetac (s : string) (tac : itactic) : temporal unit :=
tactic.timetac s tac

meta def solve1 : itactic → temporal unit :=
tactic.interactive.solve1

meta def clear : parse ident* → tactic unit :=
tactic.clear_lst

meta def explicit
  (st : parse (ident <|> pure `σ))
  (tac : tactic.interactive.itactic) : temporal unit :=
do `(%%Γ ⊢ _) ← target,
   asms ← get_assumptions,
   constructor,
   st ← tactic.intro st,
   hΓ ← tactic.intro `hΓ,
   asms.for_each (λ h, do
     e ← to_expr ``(judgement.apply %%h %%st %%hΓ),
     note h.local_pp_name none e,
     tactic.clear h),
   try $ tactic.interactive.simp none ff
       (map simp_arg_type.expr [``(function.comp),``(temporal.init)]) []
       (loc.ns $ none :: map (some ∘ expr.local_pp_name) asms),
   done <|> solve1 (do
     tactic.clear hΓ,
     try (to_expr ``(temporal.persistent %%Γ) >>= mk_instance >>= tactic.clear),
     tactic.clear Γ,
     tac)

meta def list_state_vars (t : expr) : tactic (list expr) :=
do ls ← local_context,
   pat ← pexpr_to_pattern ``(var %%t _),
   ls.mfilter (λ v, do t ← infer_type v,
                       tt <$ match_pattern pat t <|> pure ff)

meta def reverting {α} (h : expr → tactic bool) (tac : tactic α) : tactic α :=
do ls ← local_context,
   hs ← ls.mfilter h,
   tactic.revert_lst hs,
   tac <* tactic.intro_lst (hs.map expr.local_pp_name)

meta def rename' (curr : expr) (new : name) : tactic expr :=
do n ← tactic.revert curr,
   tactic.intro new
   <* tactic.intron (n - 1)

structure explicit_opts :=
  (verbose := ff)

meta def subst_state_variables (σ : expr) (p : explicit_opts) : tactic unit :=
do vs ← list_state_vars `(ℕ),
   let ns := name_set.of_list (vs.map expr.local_uniq_name),
   vs' ← reverting (λ h, do t ← infer_type h, return $ t.has_local_in ns) (do
     vs.mmap $ λ v, do
       let n := v.local_pp_name,
       let n_primed := update_name (λ s, s ++ "'") v.local_pp_name,
       n' ← mk_fresh_name,
       v ← rename v.local_pp_name n' >> get_local n',
       p ← to_expr ``(%%σ ⊨ %%v),
       try (generalize p n >> tactic.intro1),
       p' ← to_expr ``(nat.succ %%σ ⊨ %%v),
       try (generalize p' n_primed >> tactic.intro1),
       return v),
   -- ls ← local_context >>= mfilter (λ h, do t ← infer_type h, return $ σ.occurs t),
   when p.verbose trace_state,
   tactic.clear σ,
   mmap' tactic.clear vs'.reverse

meta def resetI : temporal unit := tactic.interactive.resetI

open function
meta def explicit'
  (iota : parse (tk "!")?)
  (keep_all : parse (tk "*")?)
  (rs : parse simp_arg_list)
  (hs : parse with_ident_list)
  (tac : tactic.interactive.itactic)
  (opt : explicit_opts := {})
: temporal unit :=
solve1 $
do hs ← hs.mmap get_local,
   `(%%Γ ⊢ _) ← target >>= instantiate_mvars,
   let st := `σ,
   when keep_all.is_none (do
     asms ← get_assumptions,
     (asms.diff hs).mmap' tactic.clear),
   asms ← get_assumptions,
   asms.mmap'
     (λ h, do b ← is_henceforth h,
              when b $ do
                to_expr ``(p_impl_revert (henceforth_str _ _) %%h)
                    >>= note h.local_pp_name none,
                tactic.clear h),
   asms ← get_assumptions,
   constructor,
   st ← tactic.intro st,
   hΓ ← tactic.intro `hΓ,
   asms.for_each (λ h, do
     e ← to_expr ``(judgement.apply %%h %%st %%hΓ),
     note h.local_pp_name none e,
     tactic.clear h),
   let rs' := map simp_arg_type.expr
       [``(function.comp),``(on_fun),``(prod.map),``(prod.map_left),``(prod.map_right)
       ,``(coe),``(lift_t),``(has_lift_t.lift),``(coe_t),``(has_coe_t.coe)
       ,``(coe_b),``(has_coe.coe)
       ,``(coe_fn), ``(has_coe_to_fun.coe), ``(coe_sort), ``(has_coe_to_sort.coe)
       ] ++
       rs,
   let l := (loc.ns $ none :: map (some ∘ expr.local_pp_name) asms),
   tactic.interactive.simp iota ff rs' [`predicate] l
       { fail_if_unchanged := ff },
   done <|> solve1 (do
     tactic.clear hΓ,
     try (to_expr ``(temporal.persistent %%Γ) >>= mk_instance >>= tactic.clear),
     tactic.clear Γ,
     subst_state_variables st opt,
     tac)
     -- `[rw [models_to_fun_var']]

meta def same_type (e₀ e₁ : expr) : temporal unit :=
do t₀ ← infer_type e₀,
   t₁ ← infer_type e₁,
   is_def_eq t₀ t₁

meta def «let» := tactic.interactive.«let»

meta def «have»  (h : parse ident?)
                 (q₁ : parse (tk ":" *> texpr)?)
                 (q₂ : parse $ (tk ":=" *> texpr)?)
: tactic expr :=
let h := h.get_or_else `this in
match q₁, q₂ with
| some e, some p := do
  `(%%Γ ⊢ _) ← target,
  t ← i_to_expr e,
  t' ← to_expr ``(%%Γ ⊢ %%t),
  p ← t_to_expr p,
  v ← to_expr ``(%%p : %%t'),
  tactic.assertv h t' v
| none, some p := do
  `(%%Γ ⊢ _) ← target,
  p ← t_to_expr p,
  h ← temporal.note h none p,
  (fix_assumptions Γ h) <|> return h
| some e, none := do
  `(%%Γ ⊢ _) ← target,
  e' ← i_to_expr e,
  p ← i_to_expr ``(%%Γ ⊢ %%e),
  tactic.assert h p
| none, none := do
  `(%%Γ ⊢ _) ← target,
  t ← infer_type Γ >>= beta_reduction,
  e ← mk_meta_var t,
  i_to_expr ``(%%Γ ⊢ %%e) >>= tactic.assert h
end

meta def strengthen_to (e : parse texpr) : temporal unit :=
strengthening (to_expr ``(_ ⊢ %%e) >>= change)

meta def intro (n : parse ident_?) : temporal unit :=
() <$ temporal.intros (some [n.get_or_else `_])

meta def intros : parse ident_* → temporal unit
 | [] := () <$ temporal.intros none
 | xs := () <$ temporal.intros (some xs)

meta def introv' : parse ident_* → temporal (list expr)
| []      := intros_dep
| (n::ns) := do hs  ← intros_dep,
                try (enter_list_state),
                h ← intro_aux n,
                hs' ← introv ns,
                return (hs ++ hs')

meta def introv (ls : parse ident_*) : temporal (list expr) :=
(++) <$> introv' ls <*> exit_list_state

meta def revert (ns : parse ident*) : temporal unit :=
mmap get_local ns >>= mmap' temporal.revert

meta def exact (e : parse texpr) : temporal unit :=
t_to_expr e >>= tactic.exact

meta def refine (e : parse texpr) : temporal unit :=
do t ← target,
   to_expr ``(%%e : %%t) >>= tactic.exact

meta def apply (q : parse texpr) : temporal unit :=
t_to_expr_for_apply q >>= temporal.apply

meta def trivial : temporal unit :=
`[apply of_eq_true (True_eq_true _)]

meta def rw (rs : parse rw_rules) (l : parse location) (cfg : rewrite_cfg := { }) : temporal unit :=
rewrite rs l cfg ; (trivial <|> solve_by_elim <|> reflexivity <|> return ())

meta def rewrite  (rs : parse rw_rules) (l : parse location) (cfg : rewrite_cfg := { }) : temporal unit :=
rw rs l cfg

private meta def cases_arg_p : lean.parser (option name × pexpr) :=
with_desc "(id :)? expr" $ do
  t ← texpr,
  match t with
  | (local_const x _ _ _) :=
    (tk ":" *> do t ← texpr, pure (some x, t)) <|> pure (none, t)
  | _ := pure (none, t)
  end

meta def sequent_type (p : expr) : tactic (option (expr × expr × expr)) :=
do t ← infer_type p,
   `(%%Γ ⊢ _) ← target,
   match t with
    | `(%%Γ ⊢ %%q) := return (some (Γ,p,q))
    | `(⊩ %%q) := return (some (Γ,p Γ, q))
    | _ := return none
   end

meta def break_conj (Γ p p' a b : expr) (ids : list name) : temporal unit :=
do  let h₀ : name := (ids.nth 0).get_or_else `a,
    let h₁ : name := (ids.nth 1).get_or_else `a,
    h₀ ← to_expr ``(p_and_elim_left %%a %%b %%Γ %%p') >>= note h₀ none,
    h₁ ← to_expr ``(p_and_elim_right %%a %%b %%Γ %%p') >>= note h₁ none,
    when p.is_local_constant (tactic.clear p),
    revert_lst [h₀,h₁],
    intron 2

meta def break_disj (Γ p p' a b : expr) (ids : list name) : temporal unit :=
do let h₀ : name := (ids.nth 0).get_or_else `a,
   let h₁ : name := (ids.nth 1).get_or_else `a,
   g ← target,
   note `h none p',
   revert [`h],
   when p.is_local_constant (tactic.clear p),
   apply ``(@p_or_entails_of_entails' _  %%Γ %%a %%b _ _)
   ; [ intros [h₀] , intros [h₁] ],
   tactic.swap

meta def cases_dt  (e : parse cases_arg_p) (ids : parse with_ident_list) : temporal unit :=
do e' ← to_expr e.2,
   t ← infer_type e',
   let h₀ : name := (ids.nth 0).get_or_else `a,
   let h₁ : name := (ids.nth 1).get_or_else `a,
   (do match_expr ``(tvar (_ × _)) t,
       reverting (λ h, do t ← infer_type h, return $ e'.occurs t) $ do
       h ← to_expr ``(eta_pair %%e') >>= note `h none,
       tactic.revert h,
       e' ← if e'.is_local_constant
       then mk_fresh_name >>= rename' e'
       else return e',
       to_expr ``(pair.fst ! %%e') >>= λ e, tactic.generalize e h₀ >> tactic.intro1,
       to_expr ``(pair.snd ! %%e') >>= λ e, tactic.generalize e h₁ >> tactic.intro1,
       h ← tactic.intro1,
       z ← if e'.is_local_constant then return e'
       else tactic.generalize e' `z >> tactic.intro1,
       tactic.subst z )
<|>
   tactic.interactive.cases e ids

meta def match_pexpr (p : pexpr) (e : expr) : temporal unit :=
to_expr p >>= unify e

meta def cases (e : parse cases_arg_p) (ids : parse with_ident_list) : temporal unit :=
do p' ← to_expr e.2,
   (some (Γ,p,q)) ← sequent_type p' | cases_dt e ids,
   a ← mk_mvar, b ← mk_mvar,
   (do match_pexpr ``(◻(%%a ⋀ %%b)) q,
       p₁ ← to_expr ``(eq.mp (congr_arg (judgement %%Γ) (henceforth_and %%a %%b)) %%p),
       a ← to_expr ``(◻%%a),
       b ← to_expr ``(◻%%b),
       -- p' ← mk_app `eq.mp [p₀,p],
       break_conj Γ p' p₁ a b ids) <|>
   (do match_pexpr ``(%%a ⋀ %%b) q,
       break_conj Γ p p a b ids) <|>
   (do match_pexpr ``(%%a ⋁ %%b) q,
       break_disj Γ p p a b ids) <|>
   (do match_pexpr ``(◇(%%a ⋁ %%b)) q,
       p₁ ← to_expr ``(eq.mp (congr_arg (judgement %%Γ) (eventually_or %%a %%b)) %%p),
       a ← to_expr ``(◇%%a),
       b ← to_expr ``(◇%%b),
       break_disj Γ p' p₁ a b ids) <|>
   (do match_pexpr ``(p_exists %%b) q,
       let h₀ : name := (ids.nth 0).get_or_else `_,
       let h₁ : name := (ids.nth 1).get_or_else `_,
       h ← note `h none p',
       when p'.is_local_constant (tactic.clear p'),
       revert [`h], h ← to_expr ``(p_exists_imp_eq_p_forall_imp _ _),
       tactic.rewrite_target h, intros [h₀,h₁]) <|>
   (do q ← pp q, fail format!"case expression undefined on {q}")

private meta def cases_core (p : expr) : tactic unit :=
() <$ cases (none,to_pexpr p) []

meta def by_cases : parse cases_arg_p → tactic unit
| (n, q) := do
  `(%%Γ ⊢ _) ← target,
  p ← t_to_expr q,
  let ids : list _ := n.to_monad,
  cases (none,``(predicate.em %%p %%Γ)) $ ids ++ ids

private meta def find_matching_hyp (ps : list pattern) : tactic expr :=
any_hyp $ λ h, do
  type ← infer_type h,
  ps.mfirst $ λ p, do
    match_pattern p type,
    return h

open temporal.interactive (rename')
meta def select (h : parse $ ident <* tk ":") (p : parse texpr) : temporal unit :=
do `(%%Γ ⊢ _) ← target,
   p₀ ← pexpr_to_pattern ``(%%Γ ⊢ %%p),
   p₁ ← pexpr_to_pattern p,
   any_hyp (λ h', infer_type h' >>= match_pattern p₀ >> () <$ rename' h' h)
     <|> any_hyp (λ h', infer_type h' >>= match_pattern p₁ >> () <$ rename' h' h)

meta def cases_matching (rec : parse $ (tk "*")?) (ps : parse pexpr_list_or_texpr) : temporal unit :=
do ps ← lift₂ (++) (ps.mmap pexpr_to_pattern)
                   (ps.mmap $ λ p, pexpr_to_pattern ``(_ ⊢ %%p)),
   if rec.is_none
   then find_matching_hyp ps >>= cases_core
   else tactic.focus1 $ tactic.repeat $ find_matching_hyp ps >>= cases_core

/-- Shorthand for `cases_matching` -/
meta def casesm (rec : parse $ (tk "*")?) (ps : parse pexpr_list_or_texpr) : temporal unit :=
cases_matching rec ps


-- meta def rcases (e : parse cases_arg_p)
--   (ids : parse (tk "with" *> rcases_parse)?)
-- : temporal unit :=
-- do let patts := rcases_parse.invert $ ids.get_or_else [default _],
--    _

meta def assume_negation (n : parse (tk "with" *> ident)?) : temporal unit :=
do `(_ ⊢ %%t) ← target,
   let h := n.get_or_else `h,
   cases (none, ``(predicate.em %%t)) [h,h],
   solve1 (do h ← get_local h, tactic.exact h)

meta def induction
  (obj : parse interactive.cases_arg_p)
  (rec_name : parse using_ident)
  (ids : parse with_ident_list)
  (revert : parse $ (tk "generalizing" *> ident*)?)
: tactic unit :=
do `(%%Γ ⊢ _) ← target,
   (tactic.interactive.induction obj rec_name ids revert) ;
     (local_context >>= mmap' (fix_or_clear_assumption Γ))

meta def case (ctor : parse ident*) (ids) (tac : itactic) : tactic unit :=
tactic.interactive.case ctor ids tac

meta def focus_left' (id : option name) : temporal expr :=
do `(%%Γ ⊢ _ ⋁ _) ← target | fail "expecting `_ ⋁ _`",
   `[rw [p_or_comm,← p_not_p_imp]],
   temporal.intro1 id

meta def focus_left (ids : parse with_ident_list) : temporal unit :=
() <$ focus_left' ids.head'

meta def focusing_left (ids : parse with_ident_list) (tac : itactic) : temporal unit :=
do x ← focus_left' ids.head',
   focus1 (do
     tac,
     get_local x.local_pp_name >>= temporal.revert,
     `[rw [p_not_p_imp,← p_or_comm]])

meta def focus_right' (id : option name) : temporal expr :=
do `(%%Γ ⊢ _ ⋁ _) ← target | fail "expecting `_ ⋁ _`",
   `[rw [← p_not_p_imp]],
   temporal.intro1 id

meta def focus_right (ids : parse with_ident_list) : temporal unit :=
() <$ focus_right' ids.head'

meta def focusing_right (ids : parse with_ident_list) (tac : itactic) : temporal unit :=
do x ← focus_right' ids.head',
   focus1 (do
     tac,
     get_local x.local_pp_name >>= temporal.revert,
     `[rw [p_not_p_imp]])

meta def split (greedy : parse $ (tk "!")?) (rec : parse $ (tk "*")?) : temporal unit :=
let goal := if greedy.is_some
               then target >>= force ``(_ ⊢ _ ⋀ _)
               else target in
if rec.is_some then
  focus1 $ repeat $ do
    `(%%Γ ⊢ %%p ⋀ %%q) ← goal,
    temporal.interactive.exact ``(p_and_intro %%p %%q %%Γ _ _)
else do
  `(%%Γ ⊢ %%p ⋀ %%q) ← target >>= force ``(_ ⊢ _ ⋀ _),
  temporal.interactive.exact ``(p_and_intro %%p %%q %%Γ _ _)

meta def existsi : parse pexpr_list_or_texpr → parse with_ident_list → temporal unit
| []      _ := return ()
| (p::ps) xs :=
do e ← i_to_expr p,
   have h : inhabited name, from ⟨ `_ ⟩,
   temporal.existsi e (@list.head _ h xs),
   existsi ps xs.tail

meta def clear_except :=
tactic.interactive.clear_except

meta def action (ids : parse with_ident_list) (tac : tactic.interactive.itactic) : temporal unit :=
do `[ try { simp only [predicate.p_not_comp,temporal.next_eq_action,temporal.next_eq_action',temporal.not_action] },
      try { simp only [predicate.p_not_comp,temporal.init_eq_action,temporal.init_eq_action',temporal.not_action
                      ,temporal.action_and_action,predicate.models_pred
                      ,predicate.models_prop] },
      repeat { rw ← temporal.action_imp } ],
   get_assumptions >>= list.mmap' tactic.clear,
   `(%%Γ ⊢ temporal.action %%A  %%v ) ← target,
   refine ``(temporal.unlift_action %%A %%v _),
   tactic.intro_lst [`σ,`σ'],
   mmap' tactic.intro ids,
   solve1 tac

meta def print := tactic.print

meta def repeat (tac : itactic) : temporal unit :=
tactic.repeat tac

meta def lifted_pred
  (no_dflt : parse only_flag)
  (rs : parse simp_arg_list)
  (us : parse using_idents)
: temporal unit :=
tactic.interactive.lifted_pred ff no_dflt rs us

meta def propositional : temporal unit :=
tactic.interactive.propositional

meta def match_head (e : expr) : expr → tactic unit
| e' :=
    unify e e'
<|> (do `(_ → %%e') ← whnf e',
        v ← mk_mvar,
        match_head (e'.instantiate_var v))
<|> (do `(%%Γ ⊢ _ ⟶ %%e') ← whnf e',
        e'' ← to_expr ``(%%Γ ⊢ %%e'),
        match_head e'')
<|> (do `(%%Γ ⊢ p_forall %%(expr.lam _ _ t e')) ← whnf e',
        v ← mk_meta_var t,
        e'' ← to_expr ``(%%Γ ⊢ %%(e'.instantiate_var v)),
        match_head e'')

meta def find_matching_head : expr → list expr → tactic (list expr)
| e []         := return []
| e (H :: Hs) :=
  do t ← infer_type H,
     (list.cons H <$ match_head e t <|> pure id) <*> find_matching_head e Hs

meta def apply_assumption
  (asms : option (list expr) := none)
  (tac : temporal unit := return ()) : tactic unit :=
do { ctx ← asms.to_monad <|> local_context,
     t   ← target,
     hs   ← find_matching_head t ctx,
     hs.any_of (λ H, (() <$ temporal.apply H ; tac : temporal unit)) } <|>
do { exfalso,
     ctx ← asms.to_monad <|> local_context,
     t   ← target,
     hs   ← find_matching_head t ctx,
     hs.any_of (λ H, (() <$ temporal.apply H ; tac : temporal unit)) }
<|> fail "assumption tactic failed"


/- TODO(Simon) Use  -/
meta def assumption (tac : temporal unit := return ()) : temporal unit :=
do `(_ ⊢ _) ← target | tactic.interactive.apply_assumption local_context tac,
   apply_assumption none tac <|> strengthening (apply_assumption none tac)

meta def try (tac : itactic) : temporal unit :=
tactic.try tac

meta def refl :=
do try (to_expr ``(ctx_impl _ _ _) >>= change),
   tactic.reflexivity

meta def reflexivity :=
do try (to_expr ``(ctx_impl _ _ _) >>= change),
   tactic.reflexivity

meta def ac_refl :=
do refine ``(entails_of_eq _ _ _ _) <|> refine ``(equiv_of_eq _ _ _ _),
   tactic.ac_refl

meta def unfold_coes (ids : parse ident *) (l : parse location) (cfg : unfold_config := { }) : temporal unit :=
tactic.interactive.unfold_coes l >>
tactic.interactive.unfold ids l cfg

meta def unfold (ns : parse parser.ident *) (loc : parse location) :=
tactic.interactive.unfold ns loc

meta def dunfold (ns : parse parser.ident *) (loc : parse location) :=
tactic.interactive.dunfold ns loc

meta def dsimp :=
tactic.interactive.dsimp

meta def simp (use_iota_eqn : parse (parser.tk "!")?)
              (no_dflt : parse only_flag)
              (hs : parse simp_arg_list)
              (attr_names : parse with_ident_list)
              (locat : parse location)
              (cfg : simp_config_ext := {}) : temporal unit :=
-- if locat.include_goal
-- then strengthening $ tactic.interactive.simp no_dflt hs attr_names locat cfg
do let attr_names :=
       if no_dflt
         then attr_names
         else (`tl_simp :: attr_names),
   tactic.interactive.simp use_iota_eqn no_dflt hs attr_names locat cfg,
   try refl

meta def simp_coes
              (iota : parse (tk "!")?)
              (no_dflt : parse only_flag)
              (hs : parse simp_arg_list)
              (attr_names : parse with_ident_list)
              (locat : parse location)
              (cfg : simp_config_ext := {}) : temporal unit :=
do let attr_names :=
       if no_dflt
         then attr_names
         else (`tl_simp :: attr_names),
   tactic.interactive.simp_coes iota no_dflt hs attr_names locat cfg,
   try refl

meta def exfalso : temporal unit :=
do `(%%Γ ⊢ %%p) ← target,
   `[apply False_entails %%p %%Γ _]

meta def admit : temporal unit :=
tactic.admit

meta def left : temporal unit :=
do `(%%Γ ⊢ %%p ⋁ %%q) ← target,
   apply ``(p_or_intro_left %%p %%q %%Γ _)

meta def right : temporal unit :=
do `(%%Γ ⊢ %%p ⋁ %%q) ← target,
   apply ``(p_or_intro_right %%p %%q %%Γ _)

meta def solve_by_elim : temporal unit :=
assumption $ assumption $ assumption done

meta def tauto (greedy : parse (tk "!")?) : temporal unit :=
() <$ intros [] ;
casesm (some ()) [``(_ ⋀ _),``(_ ⋁ _)] ;
split greedy (some ()) ;
solve_by_elim

meta def specialize (h : parse texpr) : temporal unit :=
tactic.interactive.specialize h

meta def type_check
   (e : parse texpr)
: tactic unit :=
do e ← t_to_expr e, tactic.type_check e, infer_type e >>= trace

def with_defaults {α} : list α → list α → list α
 | [] xs := xs
 | (x :: xs) (_ :: ys) := x :: with_defaults xs ys
 | xs [] := xs
meta def rename_bound (n : name) : expr → expr
 | (expr.app e₀ e₁) := expr.app e₀ (rename_bound e₁)
 | (expr.lam _ bi t e) := expr.lam n bi t e
 | e := e

meta def henceforth (pers : parse (tk "!")?) (l : parse location) : temporal unit :=
do when l.include_goal (do
     when pers.is_some $ persistent [],
     persistently $
       refine ``(persistent_to_henceforth _)),
   soft_apply l
         (λ h, do b ← is_henceforth h,
                  when (¬ b) $ fail format!"{h} is not of the shape `□ _`",
                  to_expr ``(p_impl_revert (henceforth_str _ _) %%h)
                    >>= note h.local_pp_name none,
                  tactic.clear h)
         (pure ())

meta def t_induction
  (pers : parse $ (tk "!") ?)
  (p : parse texpr?)
  (specs : parse $ (tk "using" *> ident*) <|> pure [])
  (ids : parse with_ident_list)
: tactic unit :=
do `(%%Γ ⊢ %%g) ← target,
   match g with
    | `(◻%%p) :=
      do let xs := (with_defaults ids [`ih]).take 1,
         ih ← to_expr ``(%%Γ ⊢ ◻(%%p ⟶ ⊙%%p)) >>= assert `ih,
         b ← is_context_persistent,
         when (b ∨ pers.is_some) $
           focus1 (do
             interactive.henceforth (some ()) (loc.ns [none]),
             intros xs),
         interactive.henceforth none (loc.ns $ specs.map some),
         tactic.swap,
         h₀ ← to_expr ``(%%Γ ⊢ %%p) >>= assert `this,
         tactic.swap,
         t_to_expr ``(temporal.induct %%p %%ih %%h₀) >>=
           tactic.exact
    | `(◇%%q ⋁ ◻%%p) :=
      do let xs := (with_defaults ids [`ih]).take 1,
         ih ← to_expr ``(%%Γ ⊢ ◻(%%p ⟶ -%%q ⟶ ⊙(%%p ⋁ %%q))) >>= assert `ih,
         b ← is_context_persistent,
         when (b ∨ pers.is_some) $
           focus1 (do
           interactive.henceforth (some ()) (loc.ns [none]),
           intros xs),
         tactic.swap,
         h₀ ← to_expr ``(%%Γ ⊢ %%p) >>= assert `this,
         tactic.swap,
         t_to_expr ``(temporal.induct_evt %%p %%q %%ih %%h₀) >>= tactic.exact
    | _ := fail "expecting goal of the form `◻p` or `◇q ⋁ ◻p`"
   end

meta def wf_induction
  (p : parse texpr)
  (rec_name : parse (tk "using" *> texpr)?)
  (ids : parse with_ident_list)
: tactic unit :=
do rec_name ← (↑rec_name : tactic pexpr) <|> return ``(has_well_founded.wf _),
   to_expr ``(well_founded.induction %%rec_name %%p) >>= tactic.apply,
   try $ to_expr p >>= tactic.clear,
   ids' ← tactic.intro_lst $ (with_defaults ids [`x,`ih_1]).take 2 ,
   h ← ids'.nth 1,
   hp ← to_expr ``((p_forall_subtype_to_fun _ _ _).mpr %%h),
   p ← rename_bound `y <$> infer_type hp,
   assertv h.local_pp_name p hp,
   tactic.clear h,
   return ()

private meta def show_aux (p : pexpr) : list expr → list expr → tactic unit
| []      r := fail "show tactic failed"
| (g::gs) r := do
  do { set_goals [g],
       g_ty ← target,
       ty ← i_to_expr p,
       unify g_ty ty,
       set_goals (g :: r.reverse ++ gs),
       tactic.change ty}
  <|>
  show_aux gs (g::r)

meta def «show» (q : parse $ texpr <* tk ",") (tac : tactic.interactive.itactic) : tactic unit :=
do gs ← get_goals,
   show_aux q gs [],
   solve1 tac

meta def rename (n₀ n₁ : parse ident) : temporal unit :=
tactic.rename n₀ n₁

meta def replace (n : parse ident)
: parse (parser.tk ":" *> texpr)? → parse (parser.tk ":=" *> texpr)? → temporal unit
| none (some prf) :=
do prf ← t_to_expr prf,
   tactic.interactive.replace n none (to_pexpr prf) >> try (simp none tt [] [] (loc.ns [some n]))
| none none :=
tactic.interactive.replace n none none
| (some t) (some prf) :=
do t' ← to_expr t >>= infer_type,
   tl ← tt <$ match_expr ``(pred' _) t' <|> pure ff,
   if tl then do
     `(%%Γ ⊢ _) ← target,
     prf' ← t_to_expr prf,
     tactic.interactive.replace n ``(%%Γ ⊢ %%t) (to_pexpr prf')
   else tactic.interactive.replace n t prf
| (some t) none :=
do t' ← to_expr t >>= infer_type,
   match_expr ``(pred' _) t' ,
   `(%%Γ ⊢ _) ← target,
   tactic.interactive.replace n ``(%%Γ ⊢ %%t) none

meta def transitivity : parse texpr? → temporal unit
 | none := apply ``(predicate.p_imp_trans )
 | (some p) := apply ``(@predicate.p_imp_trans _ _ _ %%p _ _ _)

lemma nonempty_of_tvar (α) {β} {Γ p : pred' α}
  (v  : tvar β)
  (h' : Π [nonempty β], Γ ⊢ p)
: Γ ⊢ p :=
by { lifted_pred keep,
     have inst := nonempty.intro (0 ⊨ v),
     apply (@h' inst).apply _ a, }

lemma nonempty_of_p_exists (α) {β} {Γ p : pred' α} {q : β → pred' α}
  (h  : Γ ⊢ p_exists q)
  (h' : Π [nonempty β], Γ ⊢ p)
: Γ ⊢ p :=
by { lifted_pred keep using h,
     have inst := nonempty_of_exists h,
     apply (@h' inst).apply _ a, }

meta def nonempty (t : parse texpr) : temporal unit :=
do `(%%Γ ⊢ %%p) ← target,
   q  ← mk_mvar,
   do { v ← to_expr ``(%%Γ ⊢ @p_exists _ %%t %%q) >>= find_assumption,
        refine ``(@nonempty_of_p_exists _ %%t %%Γ %%p %%q %%v _) } <|>
   do { v ← to_expr ``(tvar %%t) >>= find_assumption,
        refine ``(@nonempty_of_tvar _ %%t %%Γ %%p %%v _) },
   tactic.intro1,
   resetI,
   return ()

section historyI
variable {α : Sort*}
-- variable [nonempty α]
variable {Γ : cpred}
-- variables I N : cpred
variables J HI : tvar (α → Prop)

open classical nat

variables HN : tvar (act α)
-- variables Γ : cpred
variable h_HI : Γ ⊢ ∃∃ h : α, HI h ⋀ J h
variable h_HN : Γ ⊢ ◻(∀∀ h : α, J h ⟶ ∃∃ h' : α, HN h h' ⋀ ⊙J h')


-- private def w : ℕ → α
--  | 0 := i ⊨ x₀
--  | (succ j) := (i + j ⊨ f) (w j)


include h_HI h_HN

lemma historyI
: Γ ⊢ ∃∃ w : tvar α, HI w ⋀ ◻HN w (⊙w) ⋀ ◻J w :=
begin [temporal]
  nonempty α,
  let x₀ : tvar α := ⟨ λ i, ε x, i ⊨ HI x ∧ i ⊨ J x ⟩,
  let f : tvar (α → α) := ⟨ λ i x, ε x', i ⊨ HN x x' ∧ succ i ⊨ J x' ⟩ ,
  have := fwd_witness x₀ f Γ,
  cases this with w H, cases H with H₀ Hnext,
  existsi w,
  have : ◻J w,
  { t_induction,
    explicit' [x₀] with H₀ h_HI
    { subst w, apply_epsilon_spec, },
    henceforth! at *,
    explicit' [f] with Hnext h_HN
    { subst w', intro, apply_epsilon_spec, } },
  split*,
  explicit' with this H₀ h_HI
  { revert this, subst w,
    apply_epsilon_spec, },
  { henceforth! at *,
    explicit' [f] with this Hnext h_HN
    { subst w', apply_epsilon_spec, }, },
  assumption
end

-- variable (HN' : tvar α → tvar α → cpred)

lemma witness_elim' {P : cpred}
  (J' : tvar α → cpred)
  (HI' : tvar α → cpred)
  (HN' : tvar α → tvar α → cpred)
  (hJ : ∀ w, J w = J' w)
  (hHI : ∀ w, HI w = HI' w)
  (hHN : ∀ w, HN w (⊙w) = HN' w (⊙w))
  (h : Γ ⊢ ∀∀ w, HI' w ⋀ ◻HN' w (⊙w) ⟶ ◻J' w ⟶ P)
: Γ ⊢ P :=
begin [temporal]
  have := historyI J HI HN h_HI h_HN,
  revert this,
  simp [hJ,hHI,hHN] at ⊢ h,
  exact h,
end

end historyI

lemma witness_elim {α} {P : tvar α → cpred} {Γ : cpred}
  (x₀ : tvar α)
  (f : tvar (α → α))
  (h : Γ ⊢ ∀∀ w, w ≃ x₀ ⋀ ◻( ⊙w ≃ f w ) ⟶ P w)
: Γ ⊢ ∃∃ w, P w :=
begin [temporal]
  have := fwd_witness x₀ f Γ,
  revert this,
  apply p_exists_p_imp_p_exists,
  solve_by_elim
end

meta def lam_kabstract (e p : expr) (v : name := `_) : tactic expr :=
do t ← infer_type p,
   lam v binder_info.default t <$> kabstract e p
-- do gs ← get_goals,
--    mv ← to_expr ``(%%e = %%e) >>= mk_meta_var,
--    set_goals [mv],
--    t ← infer_type p,
--    tactic.generalize p v,
--    v ← tactic.intro1,
--    tgt ← target,
--    (e,_) ← is_eq tgt,

--    lambdas' [v] e <* set_goals gs

-- run_cmd do
-- v  ← mk_local_def `v `(ℕ),
-- v' ← mk_local_def `v `(ℕ),
-- f ← mk_local_def `f `(ℕ → ℕ → ℕ),
-- e ← to_expr ``(%%f (%%v + 1) (%%v + 2)),
-- p ← to_expr ``(%%v + 1),
-- p' ← to_expr ``(%%v + 2),
-- timetac "abstract_pattern" $ do
-- e' ← lam_kabstract e p `x,
-- e' ← lam_kabstract e' p' `y,
-- trace $ e',
-- timetac "kabstract" $ do
-- e' ← kabstract e p,
-- e' ← kabstract (e'.instantiate_var v') p',
-- trace $ e'.instantiate_var v

meta def brack_expr : lean.parser (name ⊕ pexpr) :=
sum.inl <$> ident <|> sum.inr <$> brackets "(" ")" texpr

/-- select_witness w : P w
      with h₀ h₁
      using inv
 -/
meta def select_witness
  (w : parse $ ident_ <* tk ":")
  (p : parse texpr)
  (asm : parse $ (tk "with" *> prod.mk <$> ident <*> ident?)?)
  (inv : parse $ ((tk "using" *> texpr) <|> pure (``(True))) <* tk ",")
  (tac : tactic.interactive.itactic)
: temporal unit :=
do `(%%Γ ⊢ %%q) ← target,
   u ← mk_meta_univ,
   t ← mk_meta_var (expr.sort u),
   u  ← mk_app `temporal.tvar [t],
   t' ← to_expr ``(%%u → cpred),
   (_,p) ← solve_aux t' (do
     tactic.intro w
       <* (to_expr p >>= tactic.exact)),
--        <|> fail
-- "in tactic `select_witness w : P w`, `P w` should be of the form
-- `w ≃ x₀ ⋀ ◻(⊙w ≃ f w)`, where `x₀ : tvar α`, `f : tvar (α → α)`",
   t' ← to_expr ``(tvar %%t → cpred),
   (_,J) ← solve_aux t' (do
     -- refine ``(to_fun_var _),
     tactic.intro w,
     to_expr inv  >>= tactic.exact ),
   v ← mk_local_def w u,
   p' ← head_beta (p v),
   -- q' ← head_beta (q v),
   J' ← head_beta (J v),
   (HI,HN) ← (do
     mv ← mk_mvar,
     init ← mk_mvar,
     pat ← to_expr  ``(%%init ⋀ ◻ %%mv),
     unify p' pat,
     init ← instantiate_mvars init,
     mv ← instantiate_mvars mv,
     nx_v ← to_expr ``(⊙ %%v),
     v' ← infer_type v >>= mk_local_def v.local_pp_name,
     mv ← lam_kabstract mv nx_v v.local_pp_name,
     return (init.lambdas [v], mv.lambdas [v]) ),
   new_g ← to_expr ``(%%p' ⟶ ◻%%J' ⟶ %%q),
   new_g ← to_expr ``(%%Γ ⊢ p_forall %%(new_g.lambdas [v])) >>= mk_meta_var,
   h₀ ← mk_mvar,h₁ ← mk_mvar,h₂ ← mk_mvar,h₃ ← mk_mvar,h₄ ← mk_mvar,
   let (asm₀,asm₁) := asm.get_or_else (`_,`_),
   let asm₁ := asm₁.get_or_else `_,
   -- tactic.swap,
   focus1 $ do
       -- (hJ : ∀ w, J w = J' w)
       -- (hHI : ∀ w, HI w = HI' w)
       -- (hHN : ∀ w w', HN w w' = HN' w w')
       -- (h : Γ ⊢ ∀∀ w, HI' w ⋀ ◻HN' w (⊙w) ⟶ ◻J' w ⟶ P)

     refine  ``(temporal.interactive.witness_elim'
               (to_fun_var %%J) (to_fun_var %%HI) (to_fun_var' %%HN)
               -- %%h₀ %%h₁ %%J %%HI %%h₂ %%h₃ %%new_g),
               %%h₀ %%h₁ %%J %%HI %%HN %%h₂ %%h₃ %%h₄ %%new_g),
     set_goals [h₁],
     henceforth (some ()) loc.wildcard <|> fail "foo",
     h₁::_ ← get_goals,
     set_goals [new_g],
     temporal.interactive.intros [w,asm₀,asm₁],
     new_g::_ ← get_goals,
     hs ← [h₂,h₃,h₄].mmap (λ h, do
       set_goals [h],
       focus1 `[intros, simp! only with lifted_fn],
       get_goals ),
     set_goals hs.join >> trace_state >> tac >> done,
     set_goals [new_g]

#check witness_elim'

end interactive

/- end monotonicity -/


section
open tactic tactic.interactive (unfold_coes unfold itactic assert_or_rule)
open interactive interactive.types lean lean.parser
open applicative (mmap₂ lift₂)
open functor
local postfix `?`:9001 := optional

meta def mono1 (only_pers : parse (tk "!")?) : temporal unit :=
do ex ← (if ¬ only_pers.is_some then do
      asms ← get_assumptions,
      list.band <$> asms.mmap is_henceforth
   else tt <$ interactive.persistent []),
   if ex
   then persistently $ do
          to_expr ``(ctx_impl _ _ _) >>= change,
          tactic.interactive.mono none interactive.mono_selection.both []
   else do
     to_expr ``(ctx_impl _ _ _) >>= change,
     tactic.interactive.mono none interactive.mono_selection.both []

meta def mono_n (n : ℕ) (only_pers : parse (tk "!")?)
  (dir : parse interactive.side) : temporal unit  :=
do ex ← (if ¬ only_pers.is_some then do
      asms ← get_assumptions,
      list.band <$> asms.mmap is_henceforth
   else tt <$ interactive.persistent []),
   if ex
   then persistently $ do
          to_expr ``(ctx_impl _ _ _) >>= change,
          tactic.iterate_exactly n (tactic.interactive.mono none dir [])
   else do
     to_expr ``(ctx_impl _ _ _) >>= change,
     tactic.iterate_exactly n (tactic.interactive.mono none dir [])

meta def mk_assert : pexpr ⊕ pexpr → tactic expr
| (sum.inl h) := to_expr h
| (sum.inr p) := to_expr p >>= mk_meta_var

meta def mono
  (only_pers : parse (tk "!")?)
  (many : parse (tk "*")?)
  (dir : parse interactive.side)
  (e : parse assert_or_rule?) : temporal unit :=
do ex ← (if ¬ only_pers.is_some then do
      asms ← get_assumptions,
      list.band <$> asms.mmap is_henceforth
   else tt <$ interactive.persistent []),
   -- trace ex,
   if ex
   then persistently $ do
          -- trace "foo",
          to_expr ``(ctx_impl _ _ _) >>= change,
          -- trace "bar",
          -- h ← mk_assert e,
          tactic.interactive.mono many dir []
   else do
     to_expr ``(ctx_impl _ _ _) >>= change,
     tactic.interactive.mono many dir []

meta def interactive.apply_mono (f e : parse ident) : temporal unit :=
do get_local e >>= temporal.revert,
   f ← get_local f,
   b ← is_henceforth f,
   if b then do
     interactive.persistent [],
     persistently  $ do
          to_expr ``(ctx_impl _ _ _) >>= change,
          tactic.interactive.ac_mono interactive.rep_arity.many (some $ sum.inl ``(%%f))
   else tactic.interactive.ac_mono interactive.rep_arity.many (some $ sum.inl ``(%%f))

private meta def goal_flag := optional $ tk "⊢" <|> tk "|-"

meta def interactive.guard_target
     (e : parse texpr) : temporal unit :=
do `(_ ⊢ %%t) ← target,
   e ← to_expr e,
   guard (t =ₐ e)

meta def interactive.iterate
     (n : parse small_nat)
     (tac : temporal.interactive.itactic) : temporal unit :=
do iterate_exactly n tac

meta def interactive.eventually (h : parse ident) (goal : parse goal_flag) : temporal unit :=
do `(%%Γ ⊢ %%p) ← target,
   h' ← get_local h,
   `(%%Γ' ⊢ ◇%%q) ← infer_type h' | fail format!"{h} should be a temporal formula of the form ◇_",
   is_def_eq Γ Γ',
   revert h',
   if goal.is_some then do
     `(◇ %%p) ← pure p | fail format!"expecting a goal of the form `◇ _`",
     mono1 (some ())
   else
     interactive.persistent [] >>
     persistently (do `(%%Γ ⊢ ◇%%q ⟶ %%p) ← target, refine ``(p_imp_postpone %%Γ %%q %%p _)),
   () <$ intro1 (some h)

meta def timeless (h : expr) : temporal (option name) :=
do try $ interactive.henceforth none (loc.ns [some h.local_pp_name]),
   h ← get_local h.local_pp_name,
   `(%%Γ' ⊢ %%p) ← infer_type h | return none,
   `(@coe Prop cpred _ %%p) ← return p | none <$ clear h,
   some h.local_pp_name <$ temporal.revert h

meta def interactive.note
   (h : parse ident?)
   (q₁ : parse (tk ":" *> texpr))
   (_ : parse $ tk ",")
   (tac : tactic.interactive.itactic)
: tactic expr :=
do `(%%Γ ⊢ _) ← target,
   h' ← temporal.interactive.«have» h q₁ none,
   solve1 (do
     xs ← local_context >>= mmap timeless,
     let n := xs.filter_map id,
     tactic.revert Γ,
     refine ``(ew_wk _),
     τ ← tactic.intro1,
     try $ temporal.interactive.simp none tt [] [`predicate] (loc.ns [none]) ,
     try $ tactic.interactive.TL_unfold [`init] (loc.ns [none]),
     try $ tactic.interactive.generalize none () (``(%%τ 0),`σ),
     target >>= (λ e, beta_reduction e tt) >>= change,
     intro_lst n,
     tac),
   tactic.revert h',
   refine ``(lifting_prop_asm %%Γ _),
   tactic.intro h'.local_pp_name

open tactic.interactive (rw_rules rw_rules_t rw_rule get_rule_eqn_lemmas to_expr')
open temporal.interactive (rw)

meta def interactive.rw_using
   (p  : parse cur_pos)
   (q₁ : parse (tk ":" *> texpr))
   (l : parse location)
   (_ :  parse $ tk ",")
   (tac : tactic.interactive.itactic)
: tactic unit :=
do h ← mk_fresh_name,
   h ← temporal.interactive.note h q₁ () tac,
   let rs : rw_rules_t := ⟨[{ rw_rule
                            . pos := p
                            , symm := ff
                            , rule := to_pexpr h }],none⟩,
   rw rs l,
   try (tactic.clear h)

meta def interactive.«suffices» (h : parse ident?) (t : parse (tk ":" *> texpr)?) : tactic unit :=
interactive.«have» h t none >> tactic.swap

meta def interactive.congr := tactic.interactive.congr

meta def interactive.ext := tactic.interactive.ext

run_cmd do
  let ls := [``mono,``mono1,``persistently],
  ls.for_each $ λ l, do
    env    ← get_env,
    d_name ← resolve_constant l,
    (declaration.defn _ ls ty val hints trusted) ← env.get d_name,
    (name.mk_string h _) ← return d_name,
    let new_name := `temporal.interactive <.> h,
    add_decl (declaration.defn new_name ls ty (expr.const d_name (ls.map level.param)) hints trusted)

end

end temporal

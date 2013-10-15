open Ast
open Apak
open Ark
open ArkPervasives
open BatPervasives

module StrVar = struct
  include Putil.PString
  let prime x = x ^ "'"
  let to_smt x = Smt.real_var x
  let of_smt sym = match Smt.symbol_refine sym with
    | Z3.Symbol_string str -> str
    | Z3.Symbol_int _ -> assert false
  let typ _ = TyReal
end

module K = Transition.MakeBound(StrVar) (* Transition PKA *)
module F = K.F (* Formulae *)
module T = K.T (* Terms *)
module V = K.V

let var = T.var % K.V.mk_var

let rec tr_aexp = function
  | Real_const k -> T.const k
  | Sum_exp (s, t) -> T.add (tr_aexp s) (tr_aexp t)
  | Diff_exp (s, t) -> T.sub (tr_aexp s) (tr_aexp t)
  | Mult_exp (s, t) -> T.mul (tr_aexp s) (tr_aexp t)
  | Var_exp v -> var v
  | Unneg_exp t -> T.neg (tr_aexp t)
  | Havoc_aexp -> T.var (K.V.mk_tmp "havoc" TyReal)

let to_aexp =
  let alg = function
  | OVar v ->
    begin match V.lower v with
    | Some var -> Var_exp var
    | None -> assert false
    end
  | OConst k -> Real_const k
  | OAdd (x, y) -> Sum_exp (x, y)
  | OMul (x, y) -> Mult_exp (x, y)
  | ODiv (_, _) | OFloor _ -> assert false
  in
  T.eval alg

let rec tr_bexp = function
  | Bool_const true -> F.top
  | Bool_const false -> F.bottom
  | Eq_exp (s, t) -> F.eq (tr_aexp s) (tr_aexp t)
  | Ne_exp (s, t) -> F.negate (F.eq (tr_aexp s) (tr_aexp t))
  | Gt_exp (s, t) -> F.gt (tr_aexp s) (tr_aexp t)
  | Lt_exp (s, t) -> F.lt (tr_aexp s) (tr_aexp t)
  | Ge_exp (s, t) -> F.geq (tr_aexp s) (tr_aexp t)
  | Le_exp (s, t) -> F.leq (tr_aexp s) (tr_aexp t)
  | And_exp (phi, psi) -> F.conj (tr_bexp phi) (tr_bexp psi)
  | Or_exp (phi, psi) -> F.disj (tr_bexp phi) (tr_bexp psi)
  | Not_exp phi -> F.negate (tr_bexp phi)
  | Havoc_bexp -> F.leqz (T.var (K.V.mk_tmp "havoc" TyReal))

let to_bexp =
  let alg = function
    | OOr (phi, psi) -> Or_exp (phi, psi)
    | OAnd (phi, psi) -> And_exp (phi, psi)
    | OLeqZ t -> Le_exp (to_aexp t, Real_const QQ.zero)
    | OEqZ t -> Eq_exp (to_aexp t, Real_const QQ.zero)
    | OLtZ t -> Lt_exp (to_aexp t, Real_const QQ.zero)
  in
  F.eval alg

let rec eval = function
  | Skip -> K.one 
  | Assign (v, t) -> K.assign v (tr_aexp t)
  | Seq (x, y) -> K.mul (eval x) (eval y)
  | Ite (cond, bthen, belse) ->
    let cond = tr_bexp cond in
    K.add
      (K.mul (K.assume cond) (eval bthen))
      (K.mul (K.assume (F.negate cond)) (eval belse))
  | While (cond, body) ->
    let cond = tr_bexp cond in
    K.mul
      (K.star (K.mul (K.assume cond) (eval body)))
      (K.assume (F.negate cond))
  | Assert phi -> K.assume (tr_bexp phi)
  | Print _ -> K.one
  | Assume phi -> K.assume (tr_bexp phi)

let man = Box.manager_alloc ()
let rec add_bounds path_to = function
  | Skip -> (Skip, path_to)
  | Assign (v, t) -> (Assign (v, t), K.mul path_to (K.assign v (tr_aexp t)))
  | Seq (x, y) ->
    let (x, to_y) = add_bounds path_to x in
    let (y, to_end) = add_bounds to_y y in
    (Seq (x, y), to_end)
  | Ite (cond, bthen, belse) ->
    let tr_cond = tr_bexp cond in
    let (bthen, then_path) =
      add_bounds (K.mul path_to (K.assume tr_cond)) bthen
    in
    let (belse, else_path) =
      add_bounds (K.mul path_to (K.assume (F.negate tr_cond))) belse
    in
    (Ite (cond, bthen, belse), K.add then_path else_path)
  | While (cond, body) ->
    let tr_cond = tr_bexp cond in
    let loop = K.star (K.mul (K.assume tr_cond) (eval body)) in
    let path_to = K.mul path_to loop in
    let (body, _) = add_bounds (K.mul path_to (K.assume tr_cond)) body in

    (* Remove unprimed variables *)
    let p v = match V.lower v with
      | Some v -> BatString.ends_with v "'"
      | None   -> false
    in
    (* Replace primed variables with their unprimed counterparts *) 
    let sigma v =
      match V.lower v with
      | Some x -> var (BatString.rchop x)
      | None -> assert false
    in
    let inv =
      let post = F.abstract ~exists:(Some p) man (K.to_formula path_to) in
      to_bexp (F.subst sigma (F.of_abstract post))
    in

    (While (cond, Seq (Assume inv, body)),
     K.mul path_to (K.assume (F.negate tr_cond)))
  | Assert phi -> (Assert phi, K.mul path_to (K.assume (tr_bexp phi)))
  | Print t -> (Print t, path_to)
  | Assume phi -> (Assume phi, K.mul path_to (K.assume (tr_bexp phi)))

let add_bounds (Prog s) = Prog (fst (add_bounds K.one s))
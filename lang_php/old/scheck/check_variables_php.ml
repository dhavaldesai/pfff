let check_undefined_variable ~in_lambda ~bailout var env = 
  let s = Ast.dname var in
  match lookup_env_opt s env with
  | None ->
      (* todo? could still issue an error but with the information that
       * there was an extract/eval/... around?
       *)
      if bailout
      then ()
      else 
       E.fatal (Ast.info_of_dname var) 
        (if in_lambda 
        then (E.UseOfUndefinedVariableInLambda s)
        else 
            let allvars = Env.collect_all_vars env +> List.map Ast.dname in
            let suggest = Suggest_fix_php.suggest s allvars in
            (E.UseOfUndefinedVariable (s, suggest))
        )
  | Some (scope, aref) -> incr aref

let do_in_new_scope_and_check_unused_if_strict f =
  if !E.strict 
  then do_in_new_scope_and_check_unused f
  (* otherwise use same scope *)
  else f ()
 
(*****************************************************************************)
(* Scoped visitor *)
(*****************************************************************************)

let visit_prog find_entity prog = 

  let scope = ref Ent.TopStmts in
  let bailout = ref false in
  let in_lambda = ref false in
  let in_class = ref None in

  (* todo: toremove, ugly *)
  let is_top_expr = ref true in 

  let visitor = Visitor_php.mk_visitor { Visitor_php.default_visitor with

    (* does nothing, but put here to get a sense of the "coverage" *)
    V.ktop = (fun (k, _) x ->
      match x with
      (* see kfunc_def *)
      | FuncDef _ -> k x
      (* see kclass_def and kfunc_def for the methods *)
      | ClassDef _ -> k x
      (* see kstmt and the do_in_new_scope_and_check_unused on (Program prog) *)
      | StmtList _ -> k x
      (* see kexpr *)
      | ConstantDef _ -> k x
    );

    (* -------------------------------------------------------------------- *)
    (* scoping management *)
    (* -------------------------------------------------------------------- *)

    (* function scope checking *)
    V.kfunc_def = (fun (k, _) x ->
      let kind = 
        match x.f_type with
        | FunctionRegular | FunctionLambda -> Ent.Function
        | MethodRegular | MethodAbstract -> Ent.Method Ent.RegularMethod
      in
      Common.save_excursion scope kind (fun () ->
      Common.save_excursion bailout false (fun () ->

        match x.f_type with
        | MethodAbstract _ -> 
            (* we don't want parameters in method interface to be counted
             * as unused Parameter *)
            ()
        | MethodRegular ->
            if not (Class_php.is_static_method x)
            then begin
              (* we put 1 as 'use_count' below because we are not interested
               * in error message related to $this.
               * It's legitimate to not use $this in a method.
               *)
              let dname = Ast.DName ("this", Ast.fakeInfo "this") in
              add_binding dname (S.Class, ref 1);
            end;
            do_in_new_scope_and_check_unused (fun () -> k x);
      | FunctionRegular | FunctionLambda -> 
          do_in_new_scope_and_check_unused (fun () -> k x);
      ))
    );
    V.kclass_def = (fun (k, _) x ->
      Common.save_excursion in_class (Some (Ast.name x.c_name)) (fun () ->
        do_in_new_scope_and_check_unused (fun () -> 
          k x
        ));
    );

    (* 'if', 'while', and other blocks should introduce a new scope.
     * The default function-only scope of PHP is a bad idea. 
     * Jslint thinks the same. Even if PHP has no good scoping rules, 
     * I want to force programmers like in Javascript to write code
     * that assumes good scoping rules.
     * 
     * Note that this will just create a scope and check for the
     * blocks in a a function. You also need a do_in_new_scope_and_check()
     * for the function itself which can have parameters that we
     * want to add in the environment and check for unused.
     *)
    V.kstmt_and_def_list_scope = (fun (k, _) x ->
      do_in_new_scope_and_check_unused_if_strict (fun () -> k x)
    );

    (* 
     * See do_in_new_scope_and_check_unused on (Program prog) at
     * the bottom at least.
     * 
     * Introduce a new scope for StmtList ? This would forbid user to 
     * have some statements, a func, and then more statements
     * that share the same variable. Toplevel statements
     * should not be mixed with function definitions (excepts
     * for the include/require at the top, which anyway are
     * not really, and should not be statements)
     *)

    (* -------------------------------------------------------------------- *)
    (* adding defs of dname in environment *)
    (* -------------------------------------------------------------------- *)

    V.kparameter = (fun (k,vx) x ->

    );

    V.kstmt = (fun (k, vx) x ->
      match x with
      | Globals (_, vars_list, _) ->
          vars_list +> Ast.uncomma +> List.iter (fun var ->
            match var with
            | GlobalVar dname -> 
                add_binding dname (S.Global, ref 0)
            | GlobalDollar (tok, _)  | GlobalDollarExpr (tok, _) ->
                E.warning tok E.UglyGlobalDynamic
          )

      | StaticVars (_, vars_list, _) ->
          vars_list +> Ast.uncomma +> List.iter (fun (varname, affect_opt) ->
            add_binding varname (S.Static, ref 0);
            (* TODO recurse on the affect ? *)
          )

      | Foreach (tok, _, e, _, var_either, arrow_opt, _, colon_stmt) ->
          vx (Expr e);

          let lval = 
            match var_either with
            | Left (is_ref, var) -> 
                var
            | Right lval ->
                lval
          in
          (match lval with
          | Var (dname, scope_ref) ->
              scope_ref := S.LocalIterator;
              do_in_new_scope_and_check_unused_if_strict (fun () ->
                (* People often use only one of the iterator when
                 * they do foreach like   foreach(... as $k => $v).
                 * We want to make sure that at least one of 
                 * the iterator is used, hence this trick to
                 * make them share the same ref.
                 *)
                let shared_ref = ref 0 in
                add_binding dname (S.LocalIterator, shared_ref);
                (match arrow_opt with
                | None -> ()
                | Some (_t, (is_ref, var)) -> 
                    (match var with
                    | Var (dname, scope_ref) ->
                        add_binding dname (S.LocalIterator, shared_ref);
                        scope_ref := S.LocalIterator;
                    | _ ->
                        E.warning tok E.WeirdForeachNoIteratorVar
                    );
                );
                vx (ColonStmt2 colon_stmt);
              );
          | _ -> 
              E.warning tok E.WeirdForeachNoIteratorVar
          )
      (* see kcatch below *)
      | Try _ -> k x

      (* mostly copy paste of ./pfff -dump_php tests/php/scheck/endpoint.php 
       * facebook specific? should be a hook instead to visit_prog?
       *)
      | ExprStmt(
         (Lv(
          (FunCallSimple(Name((
            ("param_post" | "param_get" | "param_request" | "param_cookie")
              as kind, i_1)),
            (i_2,
             (Left(
                Arg(
                  (ArrayLong(i_3, (i_4, array_args, i_20))
                   ))))::rest_param_xxx_args,
             i_22))
          ))), i_25) ->

          let array_args = Ast.uncomma array_args in
          let rest_param_xxx_args = Ast.uncomma rest_param_xxx_args in

          (* have passed a 'prefix' arg, or nothing *)
          if List.length rest_param_xxx_args <= 1
          then begin
              let prefix_opt =
                match rest_param_xxx_args with
                | [Arg (Sc(C(String(str_prefix, tok_prefix))))] -> 
                    Some str_prefix
                | [] ->
                    (match kind with
                    | "param_post" -> Some "post_"
                    | "param_get" -> Some "get_"
                    | "param_request" -> Some "req_"
                    | "param_cookie" -> Some "cookie_"
                    | _ -> raise Impossible
                    )
                | _ -> 
                    (* display an error? weird argument to param_xxx func? *)
                    None
              in
              prefix_opt +> Common.do_option (fun prefix ->
               array_args +> List.iter (function
               | ArrayArrowExpr((Sc(C(String((param_string, tok_param))))),
                               i_7,
                               _typ_param) ->
                   let dname = DName (prefix ^ param_string, tok_param) in
                   add_binding dname (S.Local, ref 0);
               | _ -> ()
               );
              )
          end;
          k x

      (* note: I was not handling Unset which takes a lvalue (not
       * an expression) as an argument. Because of that the kexpr
       * hook below that compute the set of vars_used_in_expr
       * was never triggered and every call to unset($avar) was not
       * considered as a use of $avar.
       * 
       * C-s "lvalue" in Ast_php to be sure all Ast elements
       * containing lvalue are appropriatly considered.
       * 
       * In the end I still decided to not consider it because
       * a mention of a variable in a $unset should not be really
       * considered as a use of variable. There should be another
       * statement in the function that actually use the variable.
       *)
      | Unset (t1, lvals_list, t2) ->
          k x

      | (TypedDeclaration (_, _, _, _)
        |Declare (_, _, _)|Use (_, _, _)
        |InlineHtml _
        |Echo (_, _, _)
        |Throw (_, _, _)|Return (_, _, _)
        |Continue (_, _, _)|Break (_, _, _)|Switch (_, _, _)
        |For (_, _, _, _, _, _, _, _, _)|Do (_, _, _, _, _)|While (_, _, _)
        |If (_, _, _, _, _)|IfColon (_, _, _, _, _, _, _, _)
        |Block _|EmptyStmt _|ExprStmt _
        ) -> k x
      | FuncDefNested _ | ClassDefNested _ ->
         k x
    );

    V.kcatch = (fun (k,vx) x ->
      let (_t, (_, (classname, dname), _), stmts) = x in
      (* The scope of catch is actually also at the function level in PHP ...
       * but for this one it is so ugly that I introduce a new scope
       * even outside strict mode. It's just too ugly.
       * 
       * todo? could use local ? could have a UnusedExceptionParameter ? 
       *)
      do_in_new_scope_and_check_unused (fun () -> 
        add_binding dname (S.LocalExn, ref 0);
        k x;
      );
    );

    (* -------------------------------------------------------------------- *)
    (* checking uses *)
    (* -------------------------------------------------------------------- *)

    V.kexpr = (fun (k, vx) x ->
      match x with
      (* todo? if the ConsList is not at the toplevel, then 
       * the code below will be executed first, which means
       * vars_used_in_expr will wrongly think vars in list() expr
       * are unused var. But this should be rare because list()
       * should be used at a statement level!
       *)
      | AssignList (_, xs, _, e) ->
          let assigned = xs +> Ast.unparen +> Ast.uncomma in
          (* Use the same trick than for LocalIterator *)
          let shared_ref = ref 0 in

          assigned +> List.iter (fun list_assign ->
            let vars = vars_used_in_any (ListAssign list_assign) in
            vars +> List.iter (fun v ->
              (* if the variable was already existing, then 
               * better not to add a new binding cos this will mask
               * a previous one which will never get its ref 
               * incremented.
               *)
              let s = Ast.dname v in
              match lookup_env_opt s !_scoped_env with
              | None ->
                  add_binding v (S.ListBinded, shared_ref)
              | Some _ ->
                  ()
            );
          );
          vx (Expr e)

      | Eval _ ->
          Common.save_excursion bailout true (fun () ->
            k x
          )
      | Lambda (l_use, def) ->
          (* reset completely the environment *)
          Common.save_excursion _scoped_env !initial_env (fun () ->
          Common.save_excursion in_lambda true (fun () ->
          Common.save_excursion bailout false (fun () ->
          Common.save_excursion is_top_expr true (fun () ->
            do_in_new_scope_and_check_unused (fun () ->

              l_use +> Common.do_option (fun (_tok, vars) ->
                vars +> Ast.unparen +> Ast.uncomma +> List.iter (function
                | LexicalVar (_is_ref, dname) ->
                    add_binding dname (S.Closed, ref 0)
                );
              );
              k x
            ))))
          )
      (* Include | ... ? *)
          
      | _ ->

       (* do the checking and environment update only for the top expressions *)
       if !is_top_expr
       then begin
        is_top_expr := false;
      
        let used = 
          vars_used_in_any (Expr x) in
        let assigned = 
          vars_assigned_in_any (Expr x) in
        let passed_by_refs =
          match find_entity with
          (* can't do much :( *)
          | None -> []
          | Some finder ->
              vars_passed_by_ref_in_any ~in_class:!in_class finder (Expr x)
        in
        (* keyword arguments should be ignored and treated as comments *)
        let keyword_args = keyword_arguments_vars_in_any (Expr x) in

        (* todo: enough? if do $x = $x + 1 then have problems? *)
        let used' = 
          used +> Common.exclude (fun v -> 
            List.mem v assigned || List.mem v passed_by_refs 
             (* actually passing a var by def can also mean it's used
              * as the variable can be a 'inout', but this special
              * case is handled specifically for passed_by_refs
              *)
          )
        in
        let assigned' = 
          assigned +> Common.exclude (fun v -> 
            List.mem v keyword_args) 
        in

        used' +> List.iter (fun v -> 
          check_undefined_variable ~in_lambda:!in_lambda ~bailout:!bailout
            v !_scoped_env
        );

        assigned' +> List.iter (fun v -> 
          (* Maybe a new local var. Add in which scope?
           * I would argue to add it only in the current nested
           * scope. If someone wants to use a var outside the block,
           * he should have initialized the var in the outer context.
           * Jslint does the same.
           *)
          let s = Ast.dname v in
          (match lookup_env_opt s !_scoped_env with
          | None -> 
              add_binding v (S.Local, ref 0);
          | Some _ ->
              (* Does an assignation counts as a use? If you only 
               * assign and never use a variable what is the point? 
               * This should be legal only for parameters (note that here
               * I talk about parameters, not arguments) passed by reference.
               *)
              ()
          )
        );
        passed_by_refs +> List.iter (fun v -> 
          (* Maybe a new local var *)
          let s = Ast.dname v in
          (match lookup_env_opt s !_scoped_env with
          | None -> 
              add_binding v (S.Local, ref 0);
          | Some (scope, aref) ->
              (* was already assigned and passed by refs, 
               * increment its use counter then
               *)
              incr aref;
          )
        );
        k x;
        is_top_expr := true;
      end
       else
         (* still recurse when not in top expr *)
         k x
    );

    V.klvalue = (fun (k,vx) x ->
      match x with
      (* the checking is done upward, in kexpr, and only for topexpr *)
      | Var (dname, scope_ref) ->
          (* assert scope_ref = S.Unknown ? *)
          let s = Ast.dname dname in
    
          (match lookup_env_opt s !_scoped_env with
          | None -> 
              scope_ref := S.Local;
          | Some (scope, _) ->
              scope_ref := scope;
          )

      | FunCallSimple (Name ("extract", _), _args) ->
          bailout := true;
          k x
      | _ -> 
          k x
    );
  }

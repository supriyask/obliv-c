(*
 *
 * Copyright (c) 2001 by
 *  George C. Necula	necula@cs.berkeley.edu
 *  Scott McPeak        smcpeak@cs.berkeley.edu
 *  Wes Weimer          weimer@cs.berkeley.edu
 *   
 * All rights reserved.  Permission to use, copy, modify and distribute
 * this software for research purposes only is hereby granted, 
 * provided that the following conditions are met: 
 * 1. Redistributions of source code must retain the above copyright notice, 
 * this list of conditions and the following disclaimer. 
 * 2. Redistributions in binary form must reproduce the above copyright notice, 
 * this list of conditions and the following disclaimer in the documentation 
 * and/or other materials provided with the distribution. 
 * 3. The name of the authors may not be used to endorse or promote products 
 * derived from  this software without specific prior written permission. 
 *
 * DISCLAIMER:
 * THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR 
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES 
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. 
 * IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS 
 * OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON 
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF 
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 *)

module P = Pretty
open Cil
module E = Errormsg
module H = Hashtbl

let debugMerge = false
let debugInlines = false

(* Try to merge structure with the same name. However, do not complain if 
 * they are not the same *)
let mergeSynonyms = true


(* Try to merge definitions of inline functions. They can appear in multiple 
 * files and we would like them all to be the same. This can slow down the 
 * merger an order of magnitude !!! *)
let mergeInlines = true

(* Check that s starts with the prefix p *)
let prefix p s = 
  let lp = String.length p in
  let ls = String.length s in
  lp <= ls && String.sub s 0 lp = p



(* A name is identified by the index of the file in which it occurs (starting 
 * at 0 with the first file) and by the actual name. We'll keep name spaces 
 * separate *)

(* We define a data structure for the equivalence classes *)
type 'a node = 
    { nname: string;   (* The actual name *)
      nfidx: int;      (* The file index *)
      ndata: 'a;       (* Data associated with the node *)
      mutable nloc: (location * int) option;  
      (* location where defined and index within the file of the definition. 
       * If None then it means that this node actually DOES NOT appear in the 
       * given file. In rare occasions we need to talk in a given file about 
       * types that are not defined in that file. This happens with undefiend 
       * structures but also due to cross-contamination of types in a few of 
       * the cases of combineType (see the definition of combineTypes). We 
       * try never to choose as representatives nodes without a definition. 
       * WE also choose the representative the one that appears earliest *)
      mutable nrep: 'a node;  (* A pointer to another node in its class (one 
                               * closer to the representative). The nrep node 
                               * is always in an earlier file, except for the 
                               * case where a name is undefined in one file 
                               * and defined in a later file. If this pointer 
                               * points to the node itself then this is the 
                               * representative.  *)
      mutable nmergedSyns: bool (* Whether we have merged the synonyms for 
                                 * the node of this name *)
    } 

(* Make a node with a self loop. This is quite tricky. *)
let mkSelfNode (eq: (int * string, 'a node) H.t) (* The equivalence table *)
               (syn: (string, 'a node) H.t) (* The synonyms table *)
               (fidx: int) (name: string) (data: 'a) 
               (l: (location * int) option) = 
  let res = { nname = name; nfidx = fidx; ndata = data; nloc = l;
              nrep  = Obj.magic 1; nmergedSyns = false; } in
  res.nrep <- res; (* Make the self cycle *)
  H.add eq (fidx, name) res; (* Add it to the proper table *)
  if mergeSynonyms && not (prefix "__anon" name) then 
    H.add syn name res;
  res

(* Find the representative with or without path compression *)
let rec find (pathcomp: bool) (nd: 'a node) = 
  if nd.nrep == nd then 
    nd
  else begin
    let res = find pathcomp nd.nrep in
    if false && pathcomp && nd.nrep != res then 
      nd.nrep <- res; (* Compress the paths *)
    res
  end


(* Union two nodes and return the new representative. We prefer as the 
 * representative a node defined earlier. We try not to use as 
 * representatives nodes that are not defined in their files. We return a 
 * function for undoing the union. Make sure that between the union and the 
 * undo you do not do path compression *)
let union (nd1: 'a node) (nd2: 'a node) : 'a node * (unit -> unit) = 
  if nd1 == nd2 then begin
      E.s (bug "unioning two identical nodes for %s(%d)" 
             nd1.nname nd1.nfidx)
  end;
  (* Move to the representatives *)
  let nd1 = find true nd1 in
  let nd2 = find true nd2 in 
  let rep, norep = (* Choose the representative *)
    if (nd1.nloc != None) =  (nd2.nloc != None) then 
      (* They have the same defined status. Choose the earliest *)
      if nd1.nfidx < nd2.nfidx then nd1, nd2 
      else if nd1.nfidx > nd2.nfidx then nd2, nd1
      else (* In the same file. Choose the one with the earliest index *) begin
        match nd1.nloc, nd2.nloc with 
          Some (_, didx1), Some (_, didx2) -> 
            if didx1 < didx2 then nd1, nd2 else
            if didx1 > didx2 then nd2, nd1 
            else begin
              ignore (warn 
                        "Merging two elements in the same file with the same idx within the file");
              nd1, nd2
            end
        | _, _ -> (* both none. Does not matter which one we choose. Should 
                   * not happen though. *)
            ignore (warn "Merging two undefined elements in the same file: %s and %s\n" nd1.nname nd2.nname);
            nd1, nd2
      end
    else (* One is defined, the other is not. Choose the defined one *)
      if nd1.nloc != None then nd1, nd2 else nd2, nd1
  in
  let oldrep = norep.nrep in
  norep.nrep <- rep; 
  rep, (fun () -> norep.nrep <- oldrep)
(*      
let union (nd1: 'a node) (nd2: 'a node) : 'a node * (unit -> unit) = 
  if nd1 == nd2 && nd1.nname = "!!!intEnumInfo!!!" then begin
    ignore (warn "unioning two identical nodes for %s(%d)" 
              nd1.nname nd1.nfidx);
    nd1, fun x -> x
  end else
    union nd1 nd2
*)
(* Find the representative for a node and compress the paths in the process *)
let findReplacement
    (pathcomp: bool)
    (eq: (int * string, 'a node) H.t)
    (fidx: int)
    (name: string) : ('a * int) option =
  try
    let nd = H.find eq (fidx, name) in
    if nd.nrep == nd then 
      None (* No replacement if this is the representative of its class *)
    else 
      let rep = find pathcomp nd in
      if rep != rep.nrep then 
        E.s (bug "find does not return the representative\n");
      Some (rep.ndata, rep.nfidx)
  with Not_found -> 
    None

(* Make a node if one does not already exists. Otherwise return the 
 * representative *)
let getNode    (eq: (int * string, 'a node) H.t)
               (syn: (string, 'a node) H.t)
               (fidx: int) (name: string) (data: 'a) 
               (l: (location * int) option) = 
  try
    let res = H.find eq (fidx, name) in
    (* Maybe we have a better location now *)
    if res.nloc = None && l != None then res.nloc <- l;
    find false res (* No path compression *)
  with Not_found -> 
    mkSelfNode eq syn fidx name data l



(* Dump a graph *)
let dumpGraph (what: string) (eq: (int * string, 'a node) H.t) : unit = 
  ignore (E.log "Equivalence graph for %s is:\n" what);
  H.iter (fun (fidx, name) nd -> 
    ignore (E.log "  %s(%d) %s-> " 
              name fidx (if nd.nloc = None then "(undef)" else ""));
    if nd.nrep == nd then 
      ignore (E.log "*\n")
    else
      ignore (E.log " %s(%d)\n" nd.nrep.nname nd.nrep.nfidx ))
    eq




(* For each name space we define a set of equivalence classes *)
let vEq: (int * string, varinfo node) H.t = H.create 111 (* Vars *)
let sEq: (int * string, compinfo node) H.t = H.create 111 (* Struct + union *)
let eEq: (int * string, enuminfo node) H.t = H.create 111 (* Enums *)
let tEq: (int * string, typeinfo node) H.t = H.create 111 (* Type names*)
let iEq: (int * string, varinfo node) H.t = H.create 111 (* Inlines *)
        
(* Sometimes we want to merge synonims. We keep some tables indexed by names. 
 * Each name is mapped to multiple exntries *)
let vSyn: (string, varinfo node) H.t = H.create 111 (* Not actually used *)
let iSyn: (string, varinfo node) H.t = H.create 111 (* Inlines *)
let sSyn: (string, compinfo node) H.t = H.create 111
let eSyn: (string, enuminfo node) H.t = H.create 111
let tSyn: (string, typeinfo node) H.t = H.create 111

(** A global environment for variables. Put in here only the non-static 
  * variables, indexed by their name.  *)
let vEnv : (string, varinfo node) H.t = H.create 111


(* A set of inline functions indexed by their printout ! *)
let inlineBodies : (P.doc, varinfo node) H.t = H.create 111

(** A number of alpha conversion tables *)
let vAlpha : (string, int ref) H.t = H.create 57 (* Variables *)
let sAlpha : (string, int ref) H.t = H.create 57 (* Structures and unions 
                                                   * have the same name space 
                                                   *)
let eAlpha : (string, int ref) H.t = H.create 57 (* Enumerations *)
let tAlpha : (string, int ref) H.t = H.create 57 (* Type names *)


(** Keep track for all global function definitions the names of the formal 
 * arguments. They might change during merging of function types if the 
 * prototype occurs after the function definition and uses different names. 
 * We'll restore the names at the end *)
let formalNames: (int * string, string list) H.t = H.create 111


  (* Accumulate here the globals in the merged file *)
let theFileTypes = ref [] 
let theFile      = ref []


(* The idnex of the current file being scanned *)
let currentFidx = ref 0 

let currentDeclIdx = ref 0 (* The index of the definition in a file *)

let pushGlobal (g: global) : unit = 
    match g with 
      GType _ | GCompTag _ | GEnumTag _ -> theFileTypes := g :: !theFileTypes
    | _ -> theFile := g :: !theFile
    
let pushGlobals gl = List.iter pushGlobal gl
    

(* Remember the composite types that we have already declared *)
let emittedCompDecls: (string, bool) H.t = H.create 113
(* Remember the variables also *)
let emittedVarDecls: (string, bool) H.t = H.create 113

(* Initialize the module *)
let init () = 
  H.clear tAlpha;
  H.clear sAlpha;
  H.clear eAlpha;
  H.clear vAlpha;

  H.clear vEnv;

  H.clear vEq;
  H.clear sEq;
  H.clear eEq;
  H.clear tEq;
  H.clear iEq;

  H.clear vSyn;
  H.clear sSyn;
  H.clear eSyn;
  H.clear tSyn;
  H.clear iSyn;

  theFile := [];
  theFileTypes := [];

  H.clear formalNames;
  H.clear inlineBodies;

  currentFidx := 0;
  currentDeclIdx := 0;

  H.clear emittedVarDecls;
  H.clear emittedCompDecls


(* Some enumerations have to be turned into an integer. We implement this by 
 * introducing a special enumeration type which we'll recognize later to be 
 * an integer *)
let intEnumInfo = 
  { ename = "!!!intEnumInfo!!!"; (* This is otherwise invalid *)
    eitems = [];
    eattr = [];
    ereferenced = false;
  }
(* And add it to the equivalence graph *)
let intEnumInfoNode = 
  getNode eEq eSyn 0 intEnumInfo.ename intEnumInfo 
                     (Some (locUnknown, 0))

    (* Combine the types. Raises the Failure exception with an error message. 
     * isdef says whether the new type is for a definition *)
type combineWhat = 
    CombineFundef (* The new definition is for a function definition. The old 
                   * is for a prototype *)
  | CombineFunarg (* Comparing a function argument type with an old prototype 
                   * arg *)
  | CombineFunret (* Comparing the return of a function with that from an old 
                   * prototype *)
  | CombineOther


let rec combineTypes (what: combineWhat) 
                     (oldfidx: int)  (oldt: typ) 
                     (fidx: int) (t: typ)  : typ = 
  match oldt, t with
  | TVoid olda, TVoid a -> TVoid (addAttributes olda a)
  | TInt (oldik, olda), TInt (ik, a) -> 
      let combineIK oldk k = 
        if oldk == k then oldk else
        (* GCC allows a function definition to have a more precise integer 
         * type than a prototype that says "int" *)
        if not !msvcMode && oldk = IInt && bitsSizeOf t <= 32 
           && (what = CombineFunarg || what = CombineFunret) 
        then 
          k
        else
          raise (Failure "(different integer types)")
      in
      TInt (combineIK oldik ik, addAttributes olda a)

  | TFloat (oldfk, olda), TFloat (fk, a) -> 
      let combineFK oldk k = 
        if oldk == k then oldk else
        (* GCC allows a function definition to have a more precise integer 
         * type than a prototype that says "double" *)
        if not !msvcMode && oldk = FDouble && k = FFloat  
           && (what = CombineFunarg || what = CombineFunret) 
        then 
          k
        else
          raise (Failure "(different floating point types)")
      in
      TFloat (combineFK oldfk fk, addAttributes olda a)

  | TEnum (oldei, olda), TEnum (ei, a) ->
      (* Matching enumerations always succeeds. But sometimes it maps both 
       * enumerations to integers *)
      matchEnumInfo oldfidx oldei fidx ei;
      TEnum (oldei, addAttributes olda a) 


        (* Strange one. But seems to be handled by GCC *)
  | TEnum (oldei, olda) , TInt(IInt, a) -> TEnum(oldei, 
                                                 addAttributes olda a)

        (* Strange one. But seems to be handled by GCC. Warning. Here we are 
         * leaking types from new to old  *)
  | TInt(IInt, olda), TEnum (ei, a) -> TEnum(ei, addAttributes olda a)
        
  | TComp (oldci, olda) , TComp (ci, a) ->
      matchCompInfo oldfidx oldci fidx ci;
      (* If we get here we were successful *)
      TComp (oldci, addAttributes olda a) 

  | TArray (oldbt, oldsz, olda), TArray (bt, sz, a) -> 
      let combbt = combineTypes CombineOther oldfidx oldbt fidx bt in
      let combinesz = 
        match oldsz, sz with
          None, Some _ -> sz
        | Some _, None -> oldsz
        | None, None -> oldsz
        | Some oldsz', Some sz' ->
            let samesz = 
              match constFold true oldsz', constFold true sz' with 
                Const(CInt64(oldi, _, _)), Const(CInt64(i, _, _)) -> oldi = i
              | _, _ -> false
            in
            if samesz then oldsz else
            raise (Failure "(different array sizes)")
      in
      TArray (combbt, combinesz, addAttributes olda a)
        
  | TPtr (oldbt, olda), TPtr (bt, a) -> 
      TPtr (combineTypes CombineOther oldfidx oldbt fidx bt, 
            addAttributes olda a)

        (* WARNING: In this case we are leaking types from new to old !! *)
  | TFun (_, _, _, [Attr("missingproto",_)]), TFun _ -> t


  | TFun _, TFun (_, _, _, [Attr("missingproto",_)]) -> oldt
        
  | TFun (oldrt, oldargs, oldva, olda), TFun (rt, args, va, a) ->
      let newrt = combineTypes 
          (if what = CombineFundef then CombineFunret else CombineOther) 
          oldfidx oldrt fidx rt 
      in
      if oldva != va then 
        raise (Failure "(diferent vararg specifiers)");
      (* If one does not have arguments, believe the one with the 
      * arguments *)
      let newargs = 
        if oldargs = None then args else
        if args = None then oldargs else
        let oldargslist = argsToList oldargs in
        let argslist = argsToList args in
        if List.length oldargslist <> List.length argslist then 
          raise (Failure "(different number of arguments)")
        else begin
          (* Go over the arguments and update the old ones with the 
          * adjusted types *)
          List.iter2 
            (fun oldarg arg -> 
              if arg.vname <> "" then oldarg.vname <- arg.vname;
              oldarg.vattr <- addAttributes oldarg.vattr arg.vattr;
              oldarg.vtype <- 
                 combineTypes 
                   (if what = CombineFundef then 
                     CombineFunarg else CombineOther) 
                   oldfidx oldarg.vtype fidx arg.vtype)
            oldargslist argslist;
          oldargs
        end
      in
      TFun (newrt, newargs, oldva, addAttributes olda a)
        
  | TNamed (oldt, olda), TNamed (t, a) -> 
      matchTypeInfo oldfidx oldt fidx t;
      (* If we get here we were able to match *)
      TNamed(oldt, addAttributes olda a) 
        
        (* Unroll first the new type *)
  | _, TNamed (t, a) -> 
      let res = combineTypes what oldfidx oldt fidx t.ttype in
      typeAddAttributes a res
        
        (* And unroll the old type as well if necessary *)
  | TNamed (oldt, a), _ -> 
      let res = combineTypes what oldfidx oldt.ttype fidx t in
      typeAddAttributes a res
        
  | _ -> raise (Failure "(different type constructors)")

(* Match two compinfos and throw a Failure if they do not match *)
and matchCompInfo (oldfidx: int) (oldci: compinfo) 
                     (fidx: int)    (ci: compinfo) : unit = 
  if oldci.cstruct <> ci.cstruct then 
    raise (Failure "(different struct/union types)");
  (* See if we have a mapping already *)
  (* Make the nodes if not already made. Actually return the 
  * representatives *)
  let oldcinode = getNode sEq sSyn oldfidx oldci.cname oldci None in
  let    cinode = getNode sEq sSyn    fidx    ci.cname    ci None in 
  if oldcinode == cinode then (* We already know they are the same *)
        ()
  else begin
    (* Replace with the representative data *)
    let oldci = oldcinode.ndata in
    let oldfidx = oldcinode.nfidx in
    let ci = cinode.ndata in
    let fidx = cinode.nfidx in
    
    let old_len = List.length oldci.cfields in
    let len = List.length ci.cfields in
    (* It is easy to catch here the case when the new structure is undefined 
     * and the old one was defined. We just reuse the old *)
    (* More complicated is the case when the old one is not defined but the 
     * new one is. We still reuse the old one and we'll take care of defining 
     * it later with the new fields. *)
    if len <> 0 && old_len <> 0 && old_len <> len then 
      raise (Failure "(different number of structure fields)");
    (* We check that they are defined in the same way. While doing this there 
     * might be recursion and we have to watch for going into an infinite 
     * loop. So we add the assumption that they are equal *)
    let newrep, undo = union oldcinode cinode in
    (* We check the fields but watch for Failure. We only do the check when 
     * the lengths are the same. Due to the code above this the other 
     * possibility is that one of the length is 0, in which case we reuse the 
     * old compinfo. *)
    if old_len = len then
      (try
        List.iter2 (fun oldf f -> 
          if oldf.fbitfield <> f.fbitfield then 
            raise (Failure "(different bitfield info)");
          if oldf.fattr <> f.fattr then 
            raise (Failure "(different field attributes)");
          (* Make sure the types are compatible *)
          let newtype = 
            combineTypes CombineOther oldfidx oldf.ftype fidx f.ftype
          in
          (* Change the type in the representative *)
          oldf.ftype <- newtype;
          ) oldci.cfields ci.cfields
      with Failure reason -> begin 
        (* Our assumption was wrong. Forget the isomorphism *)
        undo ();
        let msg = 
          P.sprint ~width:80
            (P.dprintf
               "\n\tFailed assumption that %s and %s are isomorphic %s"
               (compFullName oldci) (compFullName ci) reason) in
        raise (Failure msg)
      end);
    (* We get here when we succeeded checking that they are equal *)
    newrep.ndata.cattr <- addAttributes oldci.cattr ci.cattr;
(*        if debugMerge then 
          ignore (E.log " Renaming %s to %s\n" (compFullName ci) oldci.cname);
*)
    ()
  end

(* Match two enuminfos and throw a Failure if they do not match *)
and matchEnumInfo (oldfidx: int) (oldei: enuminfo) 
                   (fidx: int)    (ei: enuminfo) : unit = 
  (* Find the node for this enum, no path compression. *)
  let oldeinode = getNode eEq eSyn oldfidx oldei.ename oldei None in
  let einode    = getNode eEq eSyn fidx ei.ename ei None in
  if oldeinode == einode then (* We already know they are the same *)
    ()
  else begin
    (* Replace with the representative data *)
    let oldei = oldeinode.ndata in
    let oldfidx = oldeinode.nfidx in
    let ei = einode.ndata in
    let fidx = einode.nfidx in
    (* Try to match them. But if you cannot just make them both integers *)
    try
      (* We do not have a mapping. They better be defined in the same way *)
      if List.length oldei.eitems <> List.length ei.eitems then 
        raise (Failure "(different number of enumeration elements)");
      (* We check that they are defined in the same way. This is a fairly 
      * conservative check. *)
      List.iter2 
        (fun (old_iname, old_iv) (iname, iv) -> 
          if old_iname <> iname then 
            raise (Failure "(different names for enumeration items)");
          let samev = 
            match constFold true old_iv, constFold true iv with 
              Const(CInt64(oldi, _, _)), Const(CInt64(i, _, _)) -> oldi = i
            | _ -> false
          in
          if not samev then 
            raise (Failure "(different values for enumeration items)"))
        oldei.eitems ei.eitems;
      (* Set the representative *)
      let newrep, _ = union oldeinode einode in
      (* We get here if the enumerations match *)
      newrep.ndata.eattr <- addAttributes oldei.eattr ei.eattr;
      ()
    with Failure msg -> begin
      (* Get here if you cannot merge two enumeration nodes *)
      if oldeinode != intEnumInfoNode then begin
        let _ = union oldeinode intEnumInfoNode in ()
      end;
      if einode != intEnumInfoNode then begin
        let _ = union einode intEnumInfoNode in ()
      end;
    end
  end

      
(* Match two typeinfos and throw a Failure if they do not match *)
and matchTypeInfo (oldfidx: int) (oldti: typeinfo) 
                   (fidx: int)      (ti: typeinfo) : unit = 
  if oldti.tname = "" || ti.tname = "" then 
    E.s (bug "matchTypeInfo for anonymous type\n");
  (* Find the node for this enum, no path compression. *)
  let oldtnode = getNode tEq tSyn oldfidx oldti.tname oldti None in
  let    tnode = getNode tEq tSyn    fidx ti.tname    ti None in
  if oldtnode == tnode then (* We already know they are the same *)
    ()
  else begin
    (* Replace with the representative data *)
    let oldti = oldtnode.ndata in
    let oldfidx = oldtnode.nfidx in
    let ti = tnode.ndata in
    let fidx = tnode.nfidx in
    (* Check that they are the same *)
    (try
      ignore (combineTypes CombineOther oldfidx oldti.ttype fidx ti.ttype);
    with Failure reason -> begin
      let msg = 
        P.sprint ~width:80
          (P.dprintf
             "\n\tFailed assumption that %s and %s are isomorphic %s"
             oldti.tname ti.tname reason) in
      raise (Failure msg)
    end);
    let _ = union oldtnode tnode in
(*        if debugMerge then 
          ignore (E.log " Renaming type name %s to %s\n" n oldn); *)
    ()
  end

(** A visitor the renames uses of variables and types *)      
class renameVisitorClass = object (self)
  inherit nopCilVisitor 
      
      (* This is either a global variable which we took care of, or a local 
       * variable. Must do its type and attributes. *)
  method vvdec (vi: varinfo) = DoChildren

      (* This is a variable use. See if we must change it *)
  method vvrbl (vi: varinfo) : varinfo visitAction = 
    if not vi.vglob || vi.vreferenced then DoChildren else
    begin
      match findReplacement true vEq !currentFidx vi.vname with
        None -> DoChildren
      | Some (vi', _) -> 
          vi'.vreferenced <- true; 
          ChangeTo vi'
    end

          
        (* The use of a type. Change only those types whose underlying info 
         * is not a root. *)
  method vtype (t: typ) = 
    match t with 
      TComp (ci, a) when not ci.creferenced -> begin
        match findReplacement true sEq !currentFidx ci.cname with
          None -> DoChildren
        | Some (ci', oldfidx) -> 
            if false && debugMerge then 
              ignore (E.log "Renaming %s(%d) to %s(%d)\n"
                        ci.cname !currentFidx ci'.cname oldfidx);
            ChangeTo (TComp (ci', visitCilAttributes (self :> cilVisitor) a))
      end
    | TEnum (ei, a) when not ei.ereferenced -> begin
        match findReplacement true eEq !currentFidx ei.ename with
          None -> DoChildren
        | Some (ei', _) -> 
            if ei' == intEnumInfo then 
              (* This is actually our friend intEnumInfo *)
              ChangeTo (TInt(IInt, visitCilAttributes (self :> cilVisitor) a))
            else
              ChangeTo (TEnum (ei', visitCilAttributes (self :> cilVisitor) a))
      end

    | TNamed (ti, a) when not ti.treferenced -> begin
        match findReplacement true tEq !currentFidx ti.tname with
          None -> DoChildren
        | Some (ti', _) -> 
            ChangeTo (TNamed (ti', visitCilAttributes (self :> cilVisitor) a))
    end
        
    | _ -> DoChildren

  (* The Field offset might need to be changed to use new compinfo *)
  method voffs = function
      Field (f, o) -> begin
        (* See if the compinfo was changed *)
        if f.fcomp.creferenced then 
          DoChildren
        else begin
          match findReplacement true sEq !currentFidx f.fcomp.cname with
            None -> DoChildren (* We did not replace it *)
          | Some (ci', oldfidx) -> begin
              (* First, find out the index of the original field *)
              let rec indexOf (i: int) = function
                  [] -> 
                    E.s (bug "Cannot find field %s in %s(%d)\n"
                           f.fname (compFullName f.fcomp) !currentFidx)
                | f' :: rest when f' == f -> i
                | _ :: rest -> indexOf (i + 1) rest
              in
              let index = indexOf 0 f.fcomp.cfields in
              if List.length ci'.cfields <= index then 
                E.s (bug "Too few fields in replacement %s(%d) for %s(%d)\n"
                       (compFullName ci') oldfidx
                       (compFullName f.fcomp) !currentFidx);
              let f' = List.nth ci'.cfields index in 
              ChangeDoChildrenPost (Field (f', o), fun x -> x)
          end
        end
      end
    | _ -> DoChildren

end

let renameVisitor = new renameVisitorClass

(* Scan all files and do two things *)
(* 1. Initialize the alpha renaming tables with the names of the globals so 
 * that when we come in the second pass to generate new names, we do not run 
 * into conflicts.  *)
(* 2. For all declarations of globals unify their types. In the process 
 * construct a set of equivalence classes on type names, structure and 
 * enumeration tags  *)
(* 3. We clean the referenced flags *)

let rec oneFilePass1 (f:file) : unit = 
  if debugMerge || !E.verboseFlag then 
    ignore (E.log "Pre-merging (%d) %s\n" !currentFidx f.fileName);
  currentDeclIdx := 0;
  if f.globinitcalled || f.globinit <> None then
    E.s (E.warn "Merging file %s has global initializer" f.fileName);

  (* We scan each file and we look at all global varinfo. We see if globals 
   * with the same name have been encountered before and we merge those types 
   * *)
  let matchVarinfo (vi: varinfo) (l: location * int) = 
    ignore (registerAlphaName vAlpha vi.vname);
    (* Make a node for it and put it in vEq *)
    let vinode = mkSelfNode vEq vSyn !currentFidx vi.vname vi (Some l) in
    try
      let oldvinode = find true (H.find vEnv vi.vname) in 
      let oldloc, _ = 
        match oldvinode.nloc with
          None -> E.s (bug "old variable is undefined")
        | Some l -> l
      in
      let oldvi     = oldvinode.ndata in
      (* There is an old definition. We must combine the types. Do this first 
       * because it might fail *)
      let newtype = 
        try
          combineTypes CombineOther 
            oldvinode.nfidx oldvi.vtype  
            !currentFidx vi.vtype;
        with (Failure reason) -> begin
          ignore (warn "Incompatible declaration for %s. Previous was at %a %s" 
                    vi.vname d_loc oldloc reason);
          raise Not_found
        end
      in
      let newrep, _ = union oldvinode vinode in 
      (* We do not want to turn non-"const" globals into "const" one. That 
       * can happen if one file declares the variable a non-const while 
       * others declare it as "const". *)
      if hasAttribute "const" (typeAttrs vi.vtype) != 
         hasAttribute "const" (typeAttrs oldvi.vtype) then begin
        newrep.ndata.vtype <- typeRemoveAttributes ["const"] newtype;
      end else begin
        newrep.ndata.vtype <- newtype;
      end;
      (* clean up the storage.  *)
      let newstorage = 
        if vi.vstorage = oldvi.vstorage || vi.vstorage = Extern then 
          oldvi.vstorage 
        else if oldvi.vstorage = Extern then vi.vstorage 
        (* Sometimes we turn the NoStorage specifier into Static for inline 
         * functions *)
        else if oldvi.vstorage = Static && 
                vi.vstorage = NoStorage then Static 
        else begin
          ignore (warn "Inconsistent storage specification for %s. Now is %a and previous was %a at %a" 
                    vi.vname d_storage vi.vstorage d_storage oldvi.vstorage 
                    d_loc oldloc);
          vi.vstorage
        end
      in
      newrep.ndata.vstorage <- newstorage;
      newrep.ndata.vattr <- addAttributes oldvi.vattr vi.vattr;
      ()
    with Not_found -> (* Not present in the previous files. Remember it for 
                       * later  *)
      H.add vEnv vi.vname vinode

  in
  List.iter
    (function 
      | GVarDecl (vi, l) | GVar (vi, _, l) -> 
          currentLoc := l;
          incr currentDeclIdx;
          vi.vreferenced <- false;
          if vi.vstorage <> Static then begin
            matchVarinfo vi (l, !currentDeclIdx);
          end

      | GFun (fdec, l) -> 
          currentLoc := l;
          incr currentDeclIdx;
          (* Save the names of the formal arguments *)
          let _, args, _, _ = splitFunctionType fdec.svar in
          H.add formalNames (!currentFidx, fdec.svar.vname) 
            (List.map (fun f -> f.vname) (argsToList args));
          (* Force inline functions to be static *) 
          fdec.svar.vreferenced <- false;
          if fdec.sinline && fdec.svar.vstorage = NoStorage then 
            fdec.svar.vstorage <- Static;
          if fdec.svar.vstorage <> Static then begin
            matchVarinfo fdec.svar (l, !currentDeclIdx)
          end else begin
            if fdec.sinline && mergeInlines then 
              (* Just create the nodes for inline functions *)
              ignore (getNode iEq iSyn !currentFidx 
                        fdec.svar.vname fdec.svar None)
          end
              (* Make nodes for the defiend type and structure tags *)
      | GType (t, l) ->
          incr currentDeclIdx;
          t.treferenced <- false; 
          if t.tname <> "" then (* The empty names are just for introducing 
                                 * undefind comp tags *)
            ignore (getNode tEq tSyn !currentFidx t.tname t 
                      (Some (l, !currentDeclIdx)))
          else begin (* Go inside and clean the referenced flag for the 
                      * declared tags *)
            match t.ttype with 
              TComp (ci, _) -> 
                ci.creferenced <- false;
                (* Create a node for it *)
                ignore (getNode sEq sSyn !currentFidx ci.cname ci None)
                
            | TEnum (ei, _) -> 
                ei.ereferenced <- false;
                ignore (getNode eEq eSyn !currentFidx ei.ename ei None);

            | _ -> E.s (bug "Anonymous Gtype is not TComp")
          end

      | GCompTag (ci, l) -> 
          incr currentDeclIdx;
          ci.creferenced <- false;
          ignore (getNode sEq sSyn !currentFidx ci.cname ci 
                    (Some (l, !currentDeclIdx)))
      | GEnumTag (ei, l) -> 
          incr currentDeclIdx;
          ei.ereferenced <- false;
          ignore (getNode eEq eSyn !currentFidx ei.ename ei 
                    (Some (l, !currentDeclIdx)))

      | _ -> ())
    f.globals


(* Try to merge synonyms. Do not give an error if they fail to merge *)
let doMergeSynonyms 
    (syn : (string, 'a node) H.t)
    (eq : (int * string, 'a node) H.t)
    (compare : int -> 'a -> int -> 'a -> unit) (* A comparison function that 
                                                * throws Failure if no match *)
    : unit = 
  H.iter (fun n node -> 
    if not node.nmergedSyns then begin
      (* find all the nodes for the same name *)
      let all = H.find_all syn n in
      let rec tryone (classes: 'a node list) (* A number of representatives 
                                              * for this name *)
                     (nd: 'a node) : 'a node list (* Returns an expanded set 
                                                   * of classes *) = 
        nd.nmergedSyns <- true;
        (* Compare in turn with all the classes we have so far *)
        let rec compareWithClasses = function
            [] -> [nd](* No more classes. Add this as a new class *)
          | c :: restc -> 
              try
                compare c.nfidx c.ndata  nd.nfidx nd.ndata;
                (* Success. Stop here the comparison *)
                c :: restc
              with Failure _ -> (* Failed. Try next class *)
                c :: (compareWithClasses restc)
        in
        compareWithClasses classes
      in
      (* Start with an empty set of classes for this name *)
      let _ = List.fold_left tryone [] all in 
      ()
    end)
    syn


let matchInlines (oldfidx: int) (oldi: varinfo) 
                 (fidx: int) (i: varinfo) = 
  let oldinode = getNode iEq iSyn oldfidx oldi.vname oldi None in
  let    inode = getNode iEq iSyn    fidx    i.vname    i None in
  if oldinode == inode then 
    () 
  else begin
    (* Replace with the representative data *)
    let oldi = oldinode.ndata in
    let oldfidx = oldinode.nfidx in
    let i = inode.ndata in
    let fidx = inode.nfidx in
    (* There is an old definition. We must combine the types. Do this first 
     * because it might fail *)
    oldi.vtype <- 
       combineTypes CombineOther 
         oldfidx oldi.vtype fidx i.vtype;
    (* We get here if we have success *)
    (* Combine the attributes as well *)
    oldi.vattr <- addAttributes oldi.vattr i.vattr;
    (* Do not union them yet because we do not know that they are the same. 
     * We have checked only the types so far *)
    ()
  end

(***********************************************************8
 *
 *  PASS 2
 *
 *
 ************************************************************)  

  (* Now we go once more through the file and we rename the globals that we 
   * keep. We also scan the entire body and we replace references to the 
   * representative types or variables. We set the referenced flags once we 
   * replaced the names. *)
let oneFilePass2 (f: file) = 
  if debugMerge || !E.verboseFlag then 
    ignore (E.log "Final merging phase (%d): %s\n" 
              !currentFidx f.fileName);
  currentDeclIdx := 0; (* Even though we don't need it anymore *)
  let processOneGlobal (g: global) : unit = 
      (* Process a varinfo. Reuse an old one, or rename it if necessary *)
    let processVarinfo (vi: varinfo) (vloc: location) : varinfo =  
      (* Maybe it is static. Rename it then *)
      if vi.vreferenced then 
        vi (* Already done *)
      else begin
        if vi.vstorage = Static then begin
          vi.vname <- newAlphaName vAlpha vi.vname;
          vi.vid <- H.hash vi.vname;
          vi.vreferenced <- true;
          vi
        end else begin
          (* Find the representative *)
          match findReplacement true vEq !currentFidx vi.vname with
            None -> vi (* This is the representative *)
          | Some (vi', _) -> (* Reuse some previous one *)
              vi'.vreferenced <- true; (* Mark it as done already *)
              vi'.vaddrof <- vi.vaddrof || vi'.vaddrof;
              vi'
        end
      end
    in
    try
      match g with 
      | GVarDecl (vi, l) as g -> 
          currentLoc := l;
          let vi' = processVarinfo vi l in
          if vi != vi' then (* Drop this declaration *) () 
          else if H.mem emittedVarDecls vi'.vname then (* No need to keep it *)
            ()
          else begin
            H.add emittedVarDecls vi'.vname true; (* Remember that we emitted 
                                                   * it  *)
            pushGlobals (visitCilGlobal renameVisitor g)
          end
            
      | GVar (vi, init, l) as g -> 
          currentLoc := l;
          let vi' = processVarinfo vi l in
          (* We must keep this definition even if we reuse this varinfo, 
          * because maybe the previous one was a declaration *)
          H.add emittedVarDecls vi.vname true; (* Remember that we emitted it *)
          pushGlobals (visitCilGlobal renameVisitor (GVar(vi', init, l)))
            
      | GFun (fdec, l) as g -> 
          currentLoc := l;
          let origname = fdec.svar.vname in
            (* We apply the renaming *)
          fdec.svar <- processVarinfo fdec.svar l;
          let fdec' = 
            match visitCilGlobal renameVisitor g with 
              [GFun(fdec', _)] -> fdec' 
            | _ -> E.s (unimp "renameVisitor for GFun returned something else")
          in
          let g' = GFun(fdec', l) in
          (* Now restore the parameter names *)
          let _, args, _, _ = splitFunctionType fdec'.svar in
          let oldnames, foundthem = 
            try H.find formalNames (!currentFidx, origname), true
            with Not_found -> begin
              ignore (warnOpt "Cannot find %s in formalNames" origname);
              [], false
            end
          in
          if foundthem then begin
            let argl = argsToList args in
            if List.length oldnames <> List.length argl then 
              E.s (unimp "After merging the function has more arguments");
            List.iter2
              (fun oldn a -> if oldn <> "" then a.vname <- oldn)
              oldnames argl;
          end;
          
          if fdec'.sinline && mergeInlines then begin
            let printout = 
              (* Temporarily turn of printing of lines *)
              let oldprintln = !printLn in
              printLn := false;
              (* Temporarily set the name to all functions in the same way *)
              let newname = fdec'.svar.vname in
              fdec'.svar.vname <- "@@alphaname@@";
              let res = d_global () g' in
              printLn := oldprintln;
              fdec'.svar.vname <- newname;
              res
            in
            (* Make a node for this inline function using the new name. use 
             * the new name because that one will be used to lookup the 
             * replacement during renaming. *)
            let inode = 
              getNode vEq vSyn !currentFidx fdec'.svar.vname fdec'.svar None 
            in
            if debugInlines then begin
              ignore (E.log 
                        "Looking for previous definition of inline %s(%d)\n"
                        origname !currentFidx); 
            end;
            try
              let oldinode = H.find inlineBodies printout in
              if debugInlines then
                ignore (E.log "  Matches %s(%d)\n" 
                          oldinode.nname oldinode.nfidx);
              (* There is some other inline function with the same printout *)
              let _ = union oldinode inode in
              (* Clean up the vreferenced bit in the new inline, so that we 
               * can rename it *)
              fdec'.svar.vreferenced <- false;
              () (* Drop this definition *)
            with Not_found -> begin
              if debugInlines then ignore (E.log " Not found\n");
              H.add inlineBodies printout inode;
              pushGlobal g'
            end
          end else
            pushGlobal g'
              
      | GCompTag (ci, l) as g -> begin
          currentLoc := l;
          if ci.creferenced then 
            () 
          else begin
            match findReplacement true sEq !currentFidx ci.cname with
              None -> 
                (* A new one, we must rename it and keep the definition *)
                (* Make sure this is root *)
                (try 
                  let nd = H.find sEq (!currentFidx, ci.cname) in
                  if nd.nrep != nd then 
                    E.s (bug "Setting creferenced for struct %s(%d) which is not root!\n"
                           ci.cname !currentFidx);
                with Not_found -> begin
                  E.s (bug "Setting creferenced for struct %s(%d) which is not in the sEq!\n"
                         ci.cname !currentFidx);
                end);
                ci.cname <- newAlphaName sAlpha ci.cname;
                ci.creferenced <- true; 
                ci.ckey <- H.hash (compFullName ci);
                (* Now we should visit the fields as well *)
                H.add emittedCompDecls ci.cname true; (* Remember that we 
                                                       * emitted it  *)
                pushGlobals (visitCilGlobal renameVisitor g)
            | Some (oldci, oldfidx) -> begin
                (* We are not the representative. Drop this declaration 
                 * because we'll not be using it. *)
                ()
            end
          end  
      end
      | GEnumTag (ei, l) as g -> begin
          currentLoc := l;
          if ei.ereferenced then 
            () 
          else begin
            match findReplacement true eEq !currentFidx ei.ename with 
              None -> (* We must rename it *)
                ei.ename <- newAlphaName eAlpha ei.ename;
                ei.ereferenced <- true;
                (* And we must rename the items to using the same name space 
                 * as the variables *)
                ei.eitems <- 
                   List.map
                     (fun (n, i) -> newAlphaName vAlpha n, i)
                     ei.eitems;
                pushGlobals (visitCilGlobal renameVisitor g);
            | Some (ei', _) -> (* Drop this since we are reusing it from 
                                * before *)
                ()
          end
      end
      | GCompTagDecl (ci, l) -> begin
          currentLoc := l; (* This is here just to introduce an undefined 
                            * structure. But maybe the structure was defined 
                            * already.  *)
          if H.mem emittedCompDecls ci.cname then 
            () (* It was already declared *)
          else begin
            H.add emittedCompDecls ci.cname true;
            (* Keep it as a declaration *)
            pushGlobals (visitCilGlobal renameVisitor g);
          end
      end

      | GEnumTagDecl (ei, l) -> 
          currentLoc := l;
          (* Keep it as a declaration *)
          pushGlobals (visitCilGlobal renameVisitor g)
          

      | GType (ti, l) as g -> begin
          currentLoc := l;
          if ti.treferenced then 
            () 
          else begin
            match findReplacement true tEq !currentFidx ti.tname with 
              None -> (* We must rename it and keep it *)
                ti.tname <- newAlphaName tAlpha ti.tname;
                ti.treferenced <- true;
                pushGlobals (visitCilGlobal renameVisitor g);
            | Some (ti', _) ->(* Drop this since we are reusing it from 
                * before *)
                  ()
          end
      end
      | g -> pushGlobals (visitCilGlobal renameVisitor g)
  with e -> begin
    ignore (E.log "error when merging global: %s\n" (Printexc.to_string e));
    pushGlobal (GText (P.sprint 80 (P.dprintf "/* error at %t:" d_thisloc)));
    pushGlobal g;
    pushGlobal (GText ("*************** end of error*/"));
        
  end
  in
  List.iter processOneGlobal f.globals


let merge (files: file list) (newname: string) : file = 
  init ();

  (* Make the first pass over the files *)
  currentFidx := 0;
  List.iter (fun f -> oneFilePass1 f; incr currentFidx) files;

  (* Now maybe try to force synonyms to be equal *)
  if mergeSynonyms then begin
    doMergeSynonyms sSyn sEq matchCompInfo;
    doMergeSynonyms eSyn eEq matchEnumInfo;
    doMergeSynonyms tSyn tEq matchTypeInfo;
    if mergeInlines then begin 
      (* Copy all the nodes from the iEq to vEq as well. This is needed 
       * because vEq will be used for variable renaming *)
      H.iter (fun k n -> H.add vEq k n) iEq;
      doMergeSynonyms iSyn iEq matchInlines;
    end
  end;

  (* Now maybe dump the graph *)
  if debugMerge then begin
    dumpGraph "type" tEq;
    dumpGraph "struct and union" sEq;
    dumpGraph "enum" eEq;
    dumpGraph "variable" vEq;
    if mergeInlines then dumpGraph "inline" iEq;
  end;
  (* Make the second pass over the files. This is when we start rewriting the 
   * file *)
  currentFidx := 0;
  List.iter (fun f -> oneFilePass2 f; incr currentFidx) files;

  (* Now reverse the result and return the resulting file *)
  let rec revonto acc = function
      [] -> acc
    | x :: t -> revonto (x :: acc) t
  in
  let res = 
    { fileName = newname;
      globals  = revonto (revonto [] !theFile) !theFileTypes;
      globinit = None;
      globinitcalled = false } in
  init (); (* Make the GC happy *)
  res





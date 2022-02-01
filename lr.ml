
module G = Grammar
type var = G.var

type item =
  var * G.symbol array * int * var

module IS =
  Set.Make(struct
      type t = item
      let compare = compare
    end)

module Htbl = Hashtbl
module Hset = Hashset
module SS = Set.Make(String)
module SM = Map.Make(String)

let nullable g =
  let null = Hset.create 30 in
  (* collect base case, X → ε *)
  G.iter
    (fun x -> function
      | [] -> Hset.add null x
      | _  -> ()) g;
  let nullable = function
    | G.NonTerminal x -> Hset.mem null x
    | _ -> false
  in
  (* find X → Y1 Y2 ... Yn, where 
     all Ys are nullable until fixpoint *)
  let changing = ref true in
  while !changing do
    let prev = Hset.cardinal null in
    let step x ys =
      if List.for_all nullable ys then
        Hashset.add null x
    in
    G.iter step g;
    changing := Hset.cardinal null > prev
  done;
  Hset.fold SS.add null SS.empty 

let compute_nullable (g : G.t) =
  let null = nullable g in
  (function
   | G.NonTerminal x ->
      SS.mem x null
   | _ -> false)

let first (g : G.t) : SS.t SM.t =
  let map = ref SM.empty in
  let nullable = compute_nullable g in
  let first = function
    | G.Terminal y -> SS.singleton y
    | G.NonTerminal x ->
       SM.find x !map
  in
  (* initialise FIRST(X) = ∅ *)
  G.iter
    (fun x _ ->
      map := SM.add x SS.empty !map) g;
  (* cardinality summation *)
  let size () =
    SM.fold (fun _ s -> (+) (SS.cardinal s)) !map 0
  in
  let changing = ref true in
  while !changing do
    let prev = size () in
    let step x =
      let rec go = function
        | y :: ys when nullable y -> go ys
        | t :: _ ->
           map :=
             SM.add x
               (SS.union (first t) (SM.find x !map)) !map
        | _ -> ()
      in go
    in
    G.iter step g;
    changing := size () > prev
  done;
  !map

let compute_first g =
  let first = first g in
  (function
   | G.NonTerminal t -> SM.find t first
   | G.Terminal t -> SS.singleton t)

let closure g =
  let go first nullable i =
    let set = ref i in
    let changing = ref true in
    let size () = IS.cardinal !set in
    while !changing do
      let prev = size () in
      let close (_, ys, i, l) =
        if i >= Array.length ys then ()
        else
          (match ys.(i) with
           | G.NonTerminal b ->
              let prods = G.productions g b in
              let rest =
                let i' = i + 1 in
                Array.(to_list (sub ys i' (length ys - i')))
              in
              let rec follow = function
                | t :: ts when nullable t -> follow ts
                | t :: _ -> first t
                | [] -> SS.empty
              in
              (* [A → α.Bβ, l] *)
              let beta = follow rest in
              let lookaheads =
                (* if all of β is nullable, then lookahead is immediate *)
                SS.(if is_empty beta then [l] else elements beta)
              in
              (* add fresh initial items for all productions [A → a.Bβ, l] *)
              List.
              (iter
                 (fun (x, ys) ->
                   iter (fun l -> set := IS.add (x, ys, 0, l) !set) lookaheads) prods)
           | _ -> ())
      in
      IS.iter close !set;
      changing := size () > prev 
    done;
    !set
  in
  go (compute_first g) (compute_nullable g)

let goto g i s =
  let next i is =
    match i with
    | (_, ys, i, _) when i >= Array.length ys -> is
    | (x, ys, i, l) when ys.(i) = s ->
       (x, ys, i+1, l) :: is
    | _ -> is
  in
  let j = IS.(of_list (fold next i [])) in
  closure g j

module ISS =
  Set.Make(struct
      type t = IS.t * int
      let compare (_, h) (_, h') = compare h h'
    end)

module ED =
  Map.Make(struct
      type t = int * G.symbol
      let compare = compare
    end)

let items g ((s',_,_,_) as from) =
  let c : IS.t Hset.t = Hset.create 50 in
  Hset.add c (closure g (IS.singleton from));
  let symbols = G.NonTerminal s' :: G.symbols g in
  let transitions : int ED.t ref = ref ED.empty in
  let changing = ref true in
  while !changing do
    let prev = Hset.cardinal c in
    let each_set i =
      let each_symbol x =
        let next = goto g i x in
        let empty = IS.is_empty next in
        if not empty then
          transitions :=
            ED.add (Htbl.hash i, x) (Htbl.hash next) !transitions;
        if not (Hset.mem c next || empty) then
          Hset.add c next;
      in
      List.iter each_symbol symbols
    in
    Hset.iter each_set c;
    changing := Hset.cardinal c > prev
  done;
  (Hset.fold (fun i -> ISS.add (i, Htbl.hash i)) c ISS.empty, transitions)

let show_item (x, ys, i, k) =
  let ys = Array.map G.show_symbol ys in
  let ys =
    List.init (Array.length ys + 1)
      (fun i' -> if i = i' then "." else if i' > i then ys.(i'-1) else ys.(i'))
  in
  let ys =
    String.concat " " ys
  in
  Printf.sprintf "[%s -> %s, %s]" x ys k

let (>>) f g x = g (f x)

let show_item_set =
  IS.elements
  >> List.map show_item
  >> String.concat "\n"

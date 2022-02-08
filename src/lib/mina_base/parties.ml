open Core
module Digest = Kimchi_backend.Pasta.Basic.Fp

let add_caller (p : _ Party.t_) (caller : 'c) : 'c Party.t_ =
  { authorization = p.authorization; data = { p.data with caller } }

module Call_forest = struct
  let empty = Outside_hash_image.t

  module Tree = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type ('party, 'digest) t =
          { party : 'party
          ; party_digest : 'digest
          ; calls :
              (('party, 'digest) t, 'digest) With_stack_hash.Stable.V1.t list
          }
        [@@deriving sexp, compare, equal, hash, yojson]

        let to_latest = Fn.id
      end
    end]

    let rec fold_forest (ts : (_ t, _) With_stack_hash.t list) ~f ~init =
      List.fold ts ~init ~f:(fun acc { elt; stack_hash = _ } ->
          fold elt ~init:acc ~f)

    and fold { party; calls; party_digest = _ } ~f ~init =
      fold_forest calls ~f ~init:(f init party)

    let rec map (t : _ t) ~f =
      { calls = map_forest t.calls ~f
      ; party = f t.party
      ; party_digest = t.party_digest
      }

    and map_forest x ~f = List.map x ~f:(With_stack_hash.map ~f:(map ~f))

    let hash { party = _; calls; party_digest } =
      Random_oracle.hash ~init:Hash_prefix_states.party_node
        [| party_digest
         ; (match calls with [] -> empty | e :: _ -> e.stack_hash)
        |]
  end

  let fold = Tree.fold_forest

  let iteri t ~(f : int -> 'a -> unit) : unit =
    let (_ : int) = fold t ~init:0 ~f:(fun acc x -> f acc x ; acc + 1) in
    ()

  [%%versioned
  module Stable = struct
    module V1 = struct
      type ('party, 'digest) t =
        ( ('party, 'digest) Tree.Stable.V1.t
        , 'digest )
        With_stack_hash.Stable.V1.t
        list
      [@@deriving sexp, compare, equal, hash, yojson]

      let to_latest = Fn.id
    end
  end]

  let rec of_parties_list ~(party_depth : 'p -> int) (parties : 'p list) :
      ('p, unit) t =
    match parties with
    | [] ->
        []
    | p :: ps ->
        let depth = party_depth p in
        let children, post =
          List.split_while ps ~f:(fun p' -> party_depth p' > depth)
        in
        { With_stack_hash.elt =
            { Tree.party = p
            ; party_digest = ()
            ; calls = of_parties_list ~party_depth children
            }
        ; stack_hash = ()
        }
        :: of_parties_list ~party_depth post

  let to_parties_list (xs : _ t) =
    let rec collect acc (xs : _ t) =
      match xs with
      | [] ->
          acc
      | { elt = { party; calls; party_digest = _ }; stack_hash = _ } :: xs ->
          collect (collect (party :: acc) calls) xs
    in
    List.rev (collect [] xs)

  let%test_unit "Party_or_stack.of_parties_list" =
    let parties_list_1 = [ 0; 0; 0; 0 ] in
    let node i calls =
      { With_stack_hash.elt = { Tree.calls; party = i; party_digest = () }
      ; stack_hash = ()
      }
    in
    let parties_list_1_res : (int, unit) t =
      let n0 = node 0 [] in
      [ n0; n0; n0; n0 ]
    in
    [%test_eq: (int, unit) t]
      (of_parties_list ~party_depth:Fn.id parties_list_1)
      parties_list_1_res ;
    [%test_eq: int list]
      (to_parties_list (of_parties_list ~party_depth:Fn.id parties_list_1))
      parties_list_1 ;
    let parties_list_2 = [ 0; 0; 1; 1 ] in
    let parties_list_2_res = [ node 0 []; node 0 [ node 1 []; node 1 [] ] ] in
    [%test_eq: (int, unit) t]
      (of_parties_list ~party_depth:Fn.id parties_list_2)
      parties_list_2_res ;
    [%test_eq: int list]
      (to_parties_list (of_parties_list ~party_depth:Fn.id parties_list_2))
      parties_list_2 ;
    let parties_list_3 = [ 0; 0; 1; 0 ] in
    let parties_list_3_res = [ node 0 []; node 0 [ node 1 [] ]; node 0 [] ] in
    [%test_eq: (int, unit) t]
      (of_parties_list ~party_depth:Fn.id parties_list_3)
      parties_list_3_res ;
    [%test_eq: int list]
      (to_parties_list (of_parties_list ~party_depth:Fn.id parties_list_3))
      parties_list_3 ;
    let parties_list_4 = [ 0; 1; 2; 3; 2; 1; 0 ] in
    let parties_list_4_res =
      [ node 0 [ node 1 [ node 2 [ node 3 [] ]; node 2 [] ]; node 1 [] ]
      ; node 0 []
      ]
    in
    [%test_eq: (int, unit) t]
      (of_parties_list ~party_depth:Fn.id parties_list_4)
      parties_list_4_res ;
    [%test_eq: int list]
      (to_parties_list (of_parties_list ~party_depth:Fn.id parties_list_4))
      parties_list_4

  let to_parties_with_hashes_list (xs : _ t) =
    let rec collect acc (xs : _ t) =
      match xs with
      | [] ->
          acc
      | { elt = { party; calls; party_digest = _ }; stack_hash } :: xs ->
          collect (collect ((party, stack_hash) :: acc) calls) xs
    in
    List.rev (collect [] xs)

  let hash_cons hash h_tl =
    Random_oracle.hash ~init:Hash_prefix_states.party_cons [| hash; h_tl |]

  let hash = function [] -> empty | x :: _ -> With_stack_hash.stack_hash x

  let map = Tree.map_forest

  let cons ?(calls = []) (party : Party.t) (xs : _ t) : _ t =
    let party_digest = Party.Predicated.digest party.data in
    { elt = { party; party_digest; calls }
    ; stack_hash = hash_cons party_digest (hash xs)
    }
    :: xs

  let rec accumulate_hashes ~hash_party (xs : _ t) =
    let go = accumulate_hashes ~hash_party in
    match xs with
    | [] ->
        []
    | { elt = { party; calls; party_digest = _ }; stack_hash = _ } :: xs ->
        let calls = go calls in
        let xs = go xs in
        let node = { Tree.party; calls; party_digest = hash_party party } in
        let node_hash = Tree.hash node in
        { elt = node; stack_hash = hash_cons node_hash (hash xs) } :: xs

  let accumulate_hashes' xs =
    let hash_party (p : Party.t) = Party.Predicated.digest p.data in
    accumulate_hashes ~hash_party xs

  let accumulate_hashes_predicated xs =
    accumulate_hashes ~hash_party:Party.Predicated.digest xs

  let add_callers (type party party_with_caller digest id)
      (ps : (party, digest) t) ~(call_type : party -> Party.Call_type.t)
      ~(add_caller : party -> id -> party_with_caller) ~(null_id : id)
      ~(party_id : party -> id) : (party_with_caller, digest) t =
    let rec go curr_caller parent_id ps =
      let id_for_party p =
        match call_type p with
        | Delegate_call ->
            curr_caller
        | Call ->
            parent_id
      in
      match ps with
      | { With_stack_hash.elt = { Tree.party = p; party_digest; calls }
        ; stack_hash
        }
        :: ps ->
          let id = id_for_party p in
          { With_stack_hash.elt =
              { Tree.party = add_caller p id
              ; party_digest
              ; calls = go id (party_id p) calls
              }
          ; stack_hash
          }
          :: go curr_caller parent_id ps
      | [] ->
          []
    in
    go null_id null_id ps

  let add_callers' (type h) (ps : (Party.Predicated.Wire.t, h) t) :
      (Party.Predicated.t, h) t =
    add_callers ps
      ~call_type:(fun p -> p.caller)
      ~add_caller:(fun p (caller : Account_id.t) -> { p with caller })
      ~null_id:Account_id.invalid
      ~party_id:(fun p -> Account_id.create p.body.public_key p.body.token_id)

  let remove_callers (type party_with_caller party_without_sender digest id)
      (ps : (party_with_caller, digest) t) ~(equal_id : id -> id -> bool)
      ~(add_call_type :
         party_with_caller -> Party.Call_type.t -> party_without_sender)
      ~(null_id : id) ~(party_caller : party_with_caller -> id) :
      (party_without_sender, digest) t =
    let rec go parent_caller ps =
      let call_type_for_party p : Party.Call_type.t =
        if equal_id parent_caller (party_caller p) then Delegate_call else Call
      in
      match ps with
      | { With_stack_hash.elt = { Tree.party = p; party_digest; calls }
        ; stack_hash
        }
        :: ps ->
          let ty = call_type_for_party p in
          { With_stack_hash.elt =
              { Tree.party = add_call_type p ty
              ; party_digest
              ; calls = go (party_caller p) calls
              }
          ; stack_hash
          }
          :: go parent_caller ps
      | [] ->
          []
    in
    go null_id ps

  module With_hashes = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type 'data t =
          (Party.Stable.V1.t * 'data, Digest.Stable.V1.t) Stable.V1.t
        [@@deriving sexp, compare, equal, hash, yojson]

        let to_latest = Fn.id
      end
    end]

    let empty = empty

    let hash_party ((p : Party.t), _) = Party.Predicated.digest p.data

    let accumulate_hashes xs : _ t = accumulate_hashes ~hash_party xs

    let of_parties_list xs : _ t =
      of_parties_list
        ~party_depth:(fun ((p : Party.Wire.t), _) -> p.data.body.call_depth)
        xs
      |> add_callers
           ~call_type:(fun (p, _) -> p.data.caller)
           ~add_caller:(fun (p, vk) (caller : Account_id.t) ->
             ( ( { authorization = p.authorization
                 ; data = { p.data with caller }
                 }
                 : Party.t )
             , vk ))
           ~null_id:Account_id.invalid
           ~party_id:(fun (p, _) ->
             Account_id.create p.data.body.public_key p.data.body.token_id)
      |> accumulate_hashes

    let to_parties_list (x : _ t) = to_parties_list x

    let to_parties_with_hashes_list (x : _ t) = to_parties_with_hashes_list x

    let other_parties_hash' xs = of_parties_list xs |> hash

    let other_parties_hash xs =
      List.map ~f:(fun x -> (x, ())) xs |> other_parties_hash'
  end

  let is_empty : _ t -> bool = List.is_empty

  let to_list (type p) (t : (p, _) t) : p list =
    fold t ~init:[] ~f:(fun acc p -> p :: acc)
end

module Wire = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        { fee_payer : Party.Fee_payer.Stable.V1.t
        ; other_parties :
            ( Party.Body.Stable.V1.t
            , Party.Predicate.Stable.V1.t
            , Party.Call_type.Stable.V1.t
            , Control.Stable.V2.t )
            Party.Poly.Stable.V1.t
            list
        ; memo : Signed_command_memo.Stable.V1.t
        }
      [@@deriving sexp, compare, equal, hash, yojson]

      let to_latest = Fn.id
    end
  end]

  module Valid = struct
    module Stable = Stable

    type t = Stable.Latest.t
  end

  let check_depths (t : t) =
    try
      assert (t.fee_payer.data.body.call_depth = 0) ;
      let (_ : int) =
        List.fold ~init:0 t.other_parties ~f:(fun depth party ->
            let new_depth = party.data.body.call_depth in
            if new_depth >= 0 && new_depth <= depth + 1 then new_depth
            else assert false)
      in
      true
    with _ -> false

  let check (t : t) : bool = check_depths t
end

[%%versioned_binable
module Stable = struct
  module V1 = struct
    type t =
      { fee_payer : Party.Fee_payer.Stable.V1.t
      ; other_parties :
          (Party.Stable.V1.t, Digest.Stable.V1.t) Call_forest.Stable.V1.t
      ; memo : Signed_command_memo.Stable.V1.t
      }
    [@@deriving sexp, compare, equal, hash, yojson]

    let to_latest = Fn.id

    let version_byte = Base58_check.Version_bytes.snapp_command

    let description = "Parties"

    let of_wire (w : Wire.t) : t =
      { fee_payer = w.fee_payer
      ; memo = w.memo
      ; other_parties =
          w.other_parties
          |> Call_forest.of_parties_list ~party_depth:(fun (p : _ Party.t_) ->
                 p.data.body.call_depth)
          |> Call_forest.add_callers
               ~call_type:(fun (p : _ Party.t_) -> p.data.caller)
               ~add_caller ~null_id:Account_id.invalid
               ~party_id:(fun (p : _ Party.t_) ->
                 Account_id.create p.data.body.public_key p.data.body.token_id)
          |> Call_forest.accumulate_hashes ~hash_party:(fun (p : _ Party.t_) ->
                 Party.Predicated.digest p.data)
      }

    let to_wire (t : t) : Wire.t =
      { fee_payer = t.fee_payer
      ; memo = t.memo
      ; other_parties =
          Call_forest.to_parties_list
            (Call_forest.remove_callers ~equal_id:Account_id.equal
               ~add_call_type:add_caller ~null_id:Account_id.invalid
               ~party_caller:(fun p -> p.data.caller)
               t.other_parties)
      }

    include Binable.Of_binable
              (Wire.Stable.V1)
              (struct
                type nonrec t = t

                let of_binable = of_wire

                let to_binable = to_wire
              end)
  end
end]

[%%define_locally Stable.Latest.(of_wire, to_wire)]

let parties (t : t) : _ Call_forest.t =
  let p = t.fee_payer in
  let body = Party.Body.of_fee_payer p.data.body in
  let fee_payer : Party.t =
    let p = t.fee_payer in
    { authorization = Control.Signature p.authorization
    ; data =
        { body
        ; predicate = Party.Predicate.Nonce p.data.predicate
        ; caller = Account_id.invalid
        }
    }
  in
  Call_forest.cons fee_payer t.other_parties

let fee (t : t) : Currency.Fee.t = t.fee_payer.data.body.balance_change

let fee_payer_party ({ fee_payer; _ } : t) = fee_payer

let nonce (t : t) : Account.Nonce.t = (fee_payer_party t).data.predicate

let fee_token (_t : t) = Token_id.default

let fee_payer (t : t) =
  Account_id.create t.fee_payer.data.body.public_key (fee_token t)

let parties_list (t : t) : Party.t list =
  Call_forest.fold t.other_parties
    ~init:[ Party.of_fee_payer (fee_payer_party t) ]
    ~f:(Fn.flip List.cons)
  |> List.rev

let fee_excess (t : t) =
  Fee_excess.of_single (fee_token t, Currency.Fee.Signed.of_unsigned (fee t))

let accounts_accessed (t : t) =
  Call_forest.fold t.other_parties ~init:[ fee_payer t ] ~f:(fun acc p ->
      Party.account_id p :: acc)
  |> List.stable_dedup

let fee_payer_pk (t : t) = t.fee_payer.data.body.public_key

let value_if b ~then_ ~else_ = if b then then_ else else_

module Virtual = struct
  module First_party = Party

  module Bool = struct
    type t = bool

    let true_ = true

    let assert_ _ = ()

    let equal = Bool.equal

    let not = not

    let ( || ) = ( || )

    let ( && ) = ( && )
  end

  module Unit = struct
    type t = unit

    let if_ = value_if
  end

  module Ledger = Unit
  module Account = Unit

  module Amount = struct
    open Currency.Amount

    type nonrec t = t

    let if_ = value_if

    module Signed = Signed

    let zero = zero

    let ( - ) (x1 : t) (x2 : t) : Signed.t =
      Option.value_exn Signed.(of_unsigned x1 + negate (of_unsigned x2))

    let ( + ) (x1 : t) (x2 : t) : t = Option.value_exn (add x1 x2)

    let add_signed (x1 : t) (x2 : Signed.t) : t =
      let y = Option.value_exn Signed.(of_unsigned x1 + x2) in
      match y.sgn with Pos -> y.magnitude | Neg -> failwith "add_signed"
  end

  module Token_id = struct
    include Token_id

    let if_ = value_if
  end

  module Parties = struct
    type t = Party.t list

    let if_ = value_if

    type party = Party.t

    let empty = []

    let is_empty = List.is_empty

    let pop (t : t) = match t with [] -> failwith "pop" | p :: t -> (p, t)
  end
end

module Verifiable = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        { fee_payer : Party.Fee_payer.Stable.V1.t
        ; other_parties :
            Pickles.Side_loaded.Verification_key.Stable.V2.t option
            Call_forest.With_hashes.Stable.V1.t
        ; memo : Signed_command_memo.Stable.V1.t
        }
      [@@deriving sexp, compare, equal, hash, yojson]

      let to_latest = Fn.id
    end
  end]
end

let of_verifiable (t : Verifiable.t) : t =
  { fee_payer =
      { data = { t.fee_payer.data with caller = () }
      ; authorization = t.fee_payer.authorization
      }
  ; other_parties = Call_forest.map t.other_parties ~f:fst
  ; memo = t.memo
  }

module Transaction_commitment = struct
  module Stable = Kimchi_backend.Pasta.Basic.Fp.Stable

  type t = (Stable.Latest.t[@deriving sexp])

  let sexp_of_t = Stable.Latest.sexp_of_t

  let t_of_sexp = Stable.Latest.t_of_sexp

  let empty = Outside_hash_image.t

  let typ = Snark_params.Tick.Field.typ

  let create ~other_parties_hash ~protocol_state_predicate_hash ~memo_hash : t =
    Random_oracle.hash ~init:Hash_prefix.party_with_protocol_state_predicate
      [| protocol_state_predicate_hash; other_parties_hash; memo_hash |]

  let with_fee_payer (t : t) ~fee_payer_hash =
    Random_oracle.hash ~init:Hash_prefix.party_cons [| fee_payer_hash; t |]

  module Checked = struct
    type t = Pickles.Impls.Step.Field.t

    let create ~other_parties_hash ~protocol_state_predicate_hash ~memo_hash =
      Random_oracle.Checked.hash
        ~init:Hash_prefix.party_with_protocol_state_predicate
        [| protocol_state_predicate_hash; other_parties_hash; memo_hash |]

    let with_fee_payer (t : t) ~fee_payer_hash =
      Random_oracle.Checked.hash ~init:Hash_prefix.party_cons
        [| fee_payer_hash; t |]
  end
end

let other_parties_hash (t : t) = Call_forest.hash t.other_parties

let commitment (t : t) : Transaction_commitment.t =
  Transaction_commitment.create ~other_parties_hash:(other_parties_hash t)
    ~protocol_state_predicate_hash:
      (Snapp_predicate.Protocol_state.digest
         t.fee_payer.data.body.protocol_state)
    ~memo_hash:(Signed_command_memo.hash t.memo)

let of_predicated_list (ps : Party.Predicated.Wire.t list) =
  Call_forest.of_parties_list
    ~party_depth:(fun (p : Party.Predicated.Wire.t) -> p.body.call_depth)
    ps
  |> Call_forest.add_callers' |> Call_forest.accumulate_hashes_predicated

(** This module defines weights for each component of a `Parties.t` element. *)
module Weight = struct
  let party : _ Party.t_ -> int = fun _ -> 1

  let fee_payer (_fp : Party.Fee_payer.t) : int = 1

  let other_parties : (_ Party.t_, _) Call_forest.t -> int =
    Call_forest.fold ~init:0 ~f:(fun acc p -> acc + party p)

  let memo : Signed_command_memo.t -> int = fun _ -> 0
end

let weight (parties : t) : int =
  let { fee_payer; other_parties; memo } = parties in
  List.sum
    (module Int)
    ~f:Fn.id
    [ Weight.fee_payer fee_payer
    ; Weight.other_parties other_parties
    ; Weight.memo memo
    ]

module Valid = struct
  module Stable = Stable

  type t = Stable.Latest.t
end

include Codable.Make_base58_check (Stable.Latest)

(* shadow the definitions from Make_base58_check *)
[%%define_locally Stable.Latest.(of_yojson, to_yojson)]

open Core_kernel
open Async_kernel
open Snark_params
open Tick
open Let_syntax
open Unsigned_extended
open Snark_bits

(* Milliseconds since epoch *)
module Stable = struct
  module V1 = struct
    type t = UInt64.t [@@deriving bin_io, sexp, compare, eq]
  end
end

include Stable.V1
module B = Bits

let bit_length = 64

module Bits = Bits.UInt64
include B.Snarkable.UInt64 (Tick)

module Span = struct
  module Stable = struct
    module V1 = struct
      type t = UInt64.t [@@deriving bin_io, sexp, compare]
    end
  end

  include Stable.V1
  module Bits = B.UInt64
  include B.Snarkable.UInt64 (Tick)

  let of_time_span s = UInt64.of_int64 (Int64.of_float (Time.Span.to_ms s))

  let to_time_ns_span s =
    Time_ns.Span.of_ms (Int64.to_float (UInt64.to_int64 s))

  let to_ms = UInt64.to_int64

  let ( < ) = UInt64.( < )

  let ( > ) = UInt64.( > )

  let ( = ) = UInt64.( = )

  let ( <= ) = UInt64.( <= )

  let ( >= ) = UInt64.( >= )
end

module Timeout = struct
  type 'a t = {deferred: 'a Deferred.t; cancel: 'a -> unit}

  let create span action =
    let open Async_kernel.Deferred.Let_syntax in
    let cancel_ivar = Ivar.create () in
    let timeout = after (Span.to_time_ns_span span) >>| fun () -> None in
    let deferred =
      Deferred.any [Ivar.read cancel_ivar; timeout]
      >>| function None -> action () | Some x -> x
    in
    let cancel value = Ivar.fill_if_empty cancel_ivar (Some value) in
    {deferred; cancel}

  let to_deferred {deferred; _} = deferred

  let peek {deferred; _} = Deferred.peek deferred

  let cancel {cancel; _} value = cancel value
end

let field_var_to_unpacked (x: Tick.Field.Checked.t) =
  Tick.Field.Checked.unpack ~length:64 x

let diff x y = UInt64.sub x y

let diff_checked x y =
  let pack = Tick.Field.Checked.project in
  Span.unpack_var Tick.Field.Checked.Infix.(pack x - pack y)

let modulus t span = UInt64.rem t span

let unpacked_to_number var =
  let bits = Span.Unpacked.var_to_bits var in
  Number.of_bits bits

let of_time t =
  UInt64.of_int64
    (Int64.of_float (Time.Span.to_ms (Time.to_span_since_epoch t)))

let to_time t =
  Time.of_span_since_epoch
    (Time.Span.of_ms (Int64.to_float (UInt64.to_int64 t)))

let now () = of_time (Time.now ())

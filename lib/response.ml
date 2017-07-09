(*----------------------------------------------------------------------------
    Copyright (c) 2017 Inhabited Type LLC.

    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    3. Neither the name of the author nor the names of his contributors
       may be used to endorse or promote products derived from this software
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE CONTRIBUTORS ``AS IS'' AND ANY EXPRESS
    OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR
    ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
  ----------------------------------------------------------------------------*)

type t = Response0.t =
  { version : Version.t
  ; status  : Status.t
  ; reason  : string
  ; headers : Headers.t }

let create ?reason ?(version=Version.v1_1) ?(headers=Headers.empty) status =
  let reason =
    match reason with
    | Some reason -> reason
    | None ->
      begin match status with
      | #Status.standard as status -> Status.default_reason_phrase status
      | `Code _                    -> "Non-standard status code"
      end
  in
  { version; status; reason; headers }

let persistent_connection ?proxy { version; headers } =
  Message.persistent_connection ?proxy version headers

let proxy_error  = `Error `Bad_gateway
let server_error = `Error `Internal_server_error
let body_length ?(proxy=false) ~request_method { status; headers } =
  match status, request_method with
  | (`No_content | `Not_modified), _           -> `Fixed 0L
  | s, _        when Status.is_informational s -> `Fixed 0L
  | s, `CONNECT when Status.is_successful s    -> `Close_delimited
  | _, _                                       ->
    begin match Headers.get_multi headers "transfer-encoding" with
    | "chunked"::_                             -> `Chunked
    | _        ::es when List.mem "chunked" es -> `Close_delimited
    | [] | _                                   ->
      begin match Message.unique_content_length_values headers with
      | []      -> `Close_delimited
      | [ len ] ->
        let len = Message.content_length_of_string len in
        if Int64.(len >= 0L)
        then `Fixed len
        else if proxy then proxy_error else server_error
      | _       ->
        if proxy then proxy_error else server_error
      end
    end

let pp_hum fmt { version; status; reason; headers } =
  Format.fprintf fmt "((version \"%a\") (status %a) (reason %S) (headers %a))"
    Version.pp_hum version Status.pp_hum status reason Headers.pp_hum headers

module Body = struct
  type t =
    { faraday                     : Faraday.t
    ; mutable when_ready_to_write : unit -> unit
    }

  let default_ready_to_write =
    Sys.opaque_identity (fun () -> ())

  let of_faraday faraday =
    { faraday
    ; when_ready_to_write = default_ready_to_write
    }

  let create buffer =
    of_faraday (Faraday.of_bigstring buffer)

  let unsafe_faraday t =
    t.faraday

  let write_char t c =
    Faraday.write_char t.faraday c

  let write_string t ?off ?len s =
    Faraday.write_string ?off ?len t.faraday s

  let write_bigstring t ?off ?len (b:Bigstring.t) =
  (* XXX(seliopou): there is a type annontation on bigstring because of bug
   * #1699 on the OASIS bug tracker. Once that's resolved, it should no longer
   * be necessary. *)
    Faraday.write_bigstring ?off ?len t.faraday b

  let schedule_string t ?off ?len s =
    Faraday.schedule_string ?off ?len t.faraday s

  let schedule_bigstring t ?off ?len (b:Bigstring.t) =
    Faraday.schedule_bigstring ?off ?len t.faraday b

  let ready_to_write t =
    let callback = t.when_ready_to_write in
    t.when_ready_to_write <- default_ready_to_write;
    callback ()

  let flush t kontinue =
    Faraday.flush t.faraday kontinue;
    ready_to_write t

  let close t =
    Faraday.close t.faraday;
    ready_to_write t

  let is_closed t =
    Faraday.is_closed t.faraday

  let has_pending_output t =
    Faraday.has_pending_output t.faraday

  let when_ready_to_write t callback =
    if is_closed t then callback ();
    if not (t.when_ready_to_write == default_ready_to_write)
    then failwith "Response.Body.when_ready_to_write: only one callback can be registered at a time";
    t.when_ready_to_write <- callback
end

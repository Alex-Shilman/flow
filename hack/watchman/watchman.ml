(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 **)

open Core
open Utils

(*
 * Module for us to interface with Watchman, a file watching service.
 * https://facebook.github.io/watchman/
 *
 * TODO:
 *   * Connect directly to the Watchman server socket instead of spawning
 *     a client process each time
 *   * Use the BSER protocol for enhanced performance
 *)

exception Watchman_error of string
exception Timeout

let debug = false

let crash_marker_path root =
  let root_name = Path.slash_escaped_string_of_path root in
  Filename.concat GlobalConfig.tmp_dir (spf ".%s.watchman_failed" root_name)

type env = {
  socket: Timeout.in_channel * out_channel;
  root: Path.t;
  watch_root: string;
  relative_path: string;
  (* See https://facebook.github.io/watchman/docs/clockspec.html *)
  mutable clockspec: string;
  subscribe_to_changes: bool;
}

(* Some JSON processing helpers *)
module J = struct
  let try_get_val key json =
    let obj = Hh_json.get_object_exn json in
    List.Assoc.find obj key

  let get_string_val key ?default json =
    let v = try_get_val key json in
    match v, default with
    | Some v, _ -> Hh_json.get_string_exn v
    | None, Some def -> def
    | None, None -> raise Not_found

  let get_array_val key ?default json =
    let v = try_get_val key json in
    match v, default with
    | Some v, _ -> Hh_json.get_array_exn v
    | None, Some def -> def
    | None, None -> raise Not_found

  let strlist args =
    Hh_json.JSON_Array begin
      List.map args (fun arg -> Hh_json.JSON_String arg)
    end

  (* Prepend a string to a JSON array of strings. pred stands for predicate,
   * because that's how they are typically represented in watchman. See e.g.
   * https://facebook.github.io/watchman/docs/expr/allof.html *)
  let pred name args =
    let open Hh_json in
    JSON_Array (JSON_String name :: args)
end

let with_crash_record_exn root source f =
  try f ()
  with e ->
    close_out @@ open_out @@ crash_marker_path root;
    Hh_logger.exc ~prefix:("Watchman " ^ source ^ ": ") e;
    raise e

let with_crash_record root source f =
  try
    with_crash_record_exn root source f
  with _ ->
    Exit_status.(exit Watchman_failed)

let with_crash_record_opt root source f =
  Option.try_with (fun () -> with_crash_record_exn root source f)

let assert_no_error obj =
  (try
     let warning = J.get_string_val "warning" obj in
     EventLogger.watchman_warning warning;
     Hh_logger.log "Watchman warning: %s\n" warning
   with Not_found -> ());
  (try
     let error = J.get_string_val "error" obj in
     EventLogger.watchman_error error;
     raise @@ Watchman_error error
   with Not_found -> ())

let clock root = J.strlist ["clock"; root]

type watch_command = Subscribe | Query

let request_json
    ?(extra_kv=[]) ?(extra_expressions=[]) watchman_command env =
  let open Hh_json in
  let command = begin match watchman_command with
    | Subscribe -> "subscribe"
    | Query -> "query" end in
  let header =
    [JSON_String command ; JSON_String env.watch_root] @
      begin
        match watchman_command with
        | Subscribe -> [JSON_String "hh_type_check_watcher"]
        | _ -> []
      end in
  let directives = [
    JSON_Object (extra_kv @ [
      "fields", J.strlist ["name"];
      "relative_root", JSON_String env.relative_path;
      "expression", J.pred "allof" @@ (extra_expressions @ [
        J.strlist ["type"; "f"];
        J.pred "anyof" @@ [
          J.strlist ["name"; ".hhconfig"];
          J.pred "anyof" @@ [
            J.strlist ["suffix"; "php"];
            J.strlist ["suffix"; "phpt"];
            J.strlist ["suffix"; "hh"];
            J.strlist ["suffix"; "hhi"];
            J.strlist ["suffix"; "xhp"];
            (* FIXME: This is clearly wrong, but we do it to match the
             * behavior on the server-side. We need to investigate if
             * tracking js files is truly necessary.
             *)
            J.strlist ["suffix"; "js"];
          ];
        ];
        J.pred "not" @@ [
          J.pred "anyof" @@ [
            J.strlist ["dirname"; ".hg"];
            J.strlist ["dirname"; ".git"];
            J.strlist ["dirname"; ".svn"];
          ]
        ]
      ])
    ])
  ] in
  let request = JSON_Array (header @ directives) in
  request

let all_query env =
  request_json
    ~extra_expressions:([Hh_json.JSON_String "exists"])
    Query env

let since_query env =
  request_json
    ~extra_kv: ["since", Hh_json.JSON_String env.clockspec]
    Query env

let subscribe env = request_json
                      ~extra_kv:["since", Hh_json.JSON_String env.clockspec ;
                                 "defer", J.strlist ["hg.update"]]
                      Subscribe env

let watch_project root = J.strlist ["watch-project"; root]

(* See https://facebook.github.io/watchman/docs/cmd/version.html *)
let capability_check ?(optional=[]) required =
  let open Hh_json in
  JSON_Array begin
    [JSON_String "version"] @ [
      JSON_Object [
        "optional", J.strlist optional;
        "required", J.strlist required;
      ]
    ]
  end

let sanitize_watchman_response output =
  if debug then Printf.eprintf "Watchman response: %s\n%!" output;
  let response =
    try Hh_json.json_of_string output
    with e ->
      Printf.eprintf "Failed to parse string as JSON: %s\n%!" output;
      raise e
  in
  assert_no_error response;
  response

let read_with_timeout timeout ic =
   Timeout.with_timeout ~timeout
     ~do_:(fun t -> Timeout.input_line ~timeout:t ic)
     ~on_timeout:begin fun _ ->
                   EventLogger.watchman_timeout ();
                   raise Timeout
                 end

let exec ?(timeout=120) (ic, oc) json =
  let json_str = Hh_json.(json_to_string json) in
  if debug then Printf.eprintf "Watchman request: %s\n%!" json_str ;
  output_string oc json_str;
  output_string oc "\n";
  flush oc ;
  sanitize_watchman_response (read_with_timeout timeout ic)

let poll_for_updates env =
  (* Use the timeout mechanism to manage our polling frequency. *)
  let timeout = 0 in
  try
    let output = begin
      let in_channel, _  = env.socket in
      Timeout.with_timeout
        ~do_: (fun t -> Timeout.input_line ~timeout:t in_channel)
        ~timeout
        ~on_timeout:begin fun _ -> () end
    end in
    sanitize_watchman_response output
  with
  | Timeout.Timeout ->
    let clockspec = begin
        exec env.socket (clock env.watch_root) |>
          J.get_string_val "clock" end in
    let timeout_str = "{\"files\":[]," ^ "\"clock\":\"" ^ clockspec ^ "\"}" in
    Hh_json.json_of_string (timeout_str)
  | _ as e -> raise e

let extract_file_names env json =
  let files = J.get_array_val "files" json in
  let files = List.map files begin fun json ->
    let s = Hh_json.get_string_exn json in
    let abs =
      Filename.concat env.watch_root @@
      Filename.concat env.relative_path s in
    abs
  end in
  files

let get_all_files env =
  with_crash_record env.root "get_all_files" @@ fun () ->
  let response = exec env.socket (all_query env) in
  env.clockspec <- J.get_string_val "clock" response;
  extract_file_names env response

let get_changes env =
  with_crash_record env.root "get_changes" @@ fun () ->
  let response = begin
      if env.subscribe_to_changes then poll_for_updates env
      else exec env.socket (since_query env)
  end in
  (* The subscription doesn't use the clockspec post-initialization, but it may
   * be useful to keep this info around.
   *)
  env.clockspec <- J.get_string_val "clock" response;
  set_of_list @@ extract_file_names env response

let get_sockname timeout =
  let ic =
    Timeout.open_process_in "watchman" [| "watchman"; "get-sockname"; "--no-pretty" |] in
  let output = read_with_timeout timeout ic in
  assert (Timeout.close_process_in ic = Unix.WEXITED 0);
  let json = Hh_json.json_of_string output in
  J.get_string_val "sockname" json

let init timeout subscribe_to_changes root =
  with_crash_record_opt root "init" @@ fun () ->
  let root_s = Path.to_string root in
  let sockname = get_sockname timeout in
  let socket = Timeout.open_connection (Unix.ADDR_UNIX sockname) in
  ignore @@ exec socket (capability_check ["relative_root"]);
  let response = exec socket (watch_project root_s) in
  let watch_root = J.get_string_val "watch" response in
  let relative_path = J.get_string_val "relative_path" ~default:"" response in

  let clockspec =
    exec socket (clock watch_root) |> J.get_string_val "clock" in
  let env = {
    socket;
    root;
    watch_root;
    relative_path;
    clockspec;
    subscribe_to_changes;
  } in
  if env.subscribe_to_changes then (ignore @@ exec env.socket (subscribe env)) ;
  env
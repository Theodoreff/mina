open Core_kernel
open Async
open Integration_test_lib
open Mina_transaction

(* exclude from bisect_ppx to avoid type error on GraphQL modules *)
[@@@coverage exclude_file]

let mina_archive_container_id = "archive"

let mina_archive_username = "mina"

let mina_archive_pw = "zo3moong7moog4Iep7eNgo3iecaesahH"

let postgres_url =
  Printf.sprintf "postgres://%s:%s@archive-1-postgresql:5432/archive"
    mina_archive_username mina_archive_pw

let node_password = "naughty blue worm"

type config =
  { testnet_name : string
  ; cluster : string
  ; namespace : string
  ; graphql_enabled : bool
  }

let base_kube_args { cluster; namespace; _ } =
  [ "--cluster"; cluster; "--namespace"; namespace ]

module Node = struct
  type pod_info =
    { network_keypair : Network_keypair.t option
    ; primary_container_id : string
          (* this is going to be probably either "mina" or "worker" *)
    ; has_archive_container : bool
          (* archive pods have a "mina" container and an "archive" container alongside *)
    }

  type t =
    { app_id : string
    ; pod_ids : string list
    ; pod_info : pod_info
    ; config : config
    }

  let id { pod_ids; _ } = List.hd_exn pod_ids

  let network_keypair { pod_info = { network_keypair; _ }; _ } = network_keypair

  let base_kube_args t = [ "--cluster"; t.cluster; "--namespace"; t.namespace ]

  let get_logs_in_container ?container_id { pod_ids; config; pod_info; _ } =
    let container_id =
      Option.value container_id ~default:pod_info.primary_container_id
    in
    let%bind cwd = Unix.getcwd () in
    Integration_test_lib.Util.run_cmd_or_hard_error ~exit_code:13 cwd "kubectl"
      ( base_kube_args config
      @ [ "logs"; "-c"; container_id; List.hd_exn pod_ids ] )

  let run_in_container ?(exit_code = 10) ?container_id ?override_with_pod_id
      ~cmd t =
    let { config; pod_info; _ } = t in
    let pod_id =
      match override_with_pod_id with
      | Some pid ->
          pid
      | None ->
          List.hd_exn t.pod_ids
    in
    let container_id =
      Option.value container_id ~default:pod_info.primary_container_id
    in
    let%bind cwd = Unix.getcwd () in
    Integration_test_lib.Util.run_cmd_or_hard_error ~exit_code cwd "kubectl"
      ( base_kube_args config
      @ [ "exec"; "-c"; container_id; "-i"; pod_id; "--" ]
      @ cmd )

  let cp_string_to_container_file ?container_id ~str ~dest t =
    let { pod_ids; config; pod_info; _ } = t in
    let container_id =
      Option.value container_id ~default:pod_info.primary_container_id
    in
    let tmp_file, oc =
      Caml.Filename.open_temp_file ~temp_dir:Filename.temp_dir_name
        "integration_test_cp_string" ".tmp"
    in
    Out_channel.output_string oc str ;
    Out_channel.close oc ;
    let%bind cwd = Unix.getcwd () in
    let dest_file =
      sprintf "%s/%s:%s" config.namespace (List.hd_exn pod_ids) dest
    in
    Integration_test_lib.Util.run_cmd_or_error cwd "kubectl"
      (base_kube_args config @ [ "cp"; "-c"; container_id; tmp_file; dest_file ])

  let start ~fresh_state node : unit Malleable_error.t =
    let open Malleable_error.Let_syntax in
    let%bind () =
      if fresh_state then
        run_in_container node ~cmd:[ "sh"; "-c"; "rm -rf .mina-config/*" ]
        >>| ignore
      else Malleable_error.return ()
    in
    run_in_container ~exit_code:11 node ~cmd:[ "/start.sh" ] >>| ignore

  let stop node =
    let open Malleable_error.Let_syntax in
    run_in_container ~exit_code:12 node ~cmd:[ "/stop.sh" ] >>| ignore

  let logger_metadata node =
    [ ("namespace", `String node.config.namespace)
    ; ("app_id", `String node.app_id)
    ; ("pod_id", `String (List.hd_exn node.pod_ids))
    ]

  module Scalars = Graphql_lib.Scalars

  module Graphql = struct
    let ingress_uri node =
      let host =
        sprintf "%s.graphql.test.o1test.net" node.config.testnet_name
      in
      let path = sprintf "/%s/graphql" node.app_id in
      Uri.make ~scheme:"http" ~host ~path ~port:80 ()

    module Client = Graphql_lib.Client.Make (struct
      let preprocess_variables_string = Fn.id

      let headers = String.Map.empty
    end)

    (* graphql_ppx uses Stdlib symbols instead of Base *)
    open Stdlib
    module Encoders = Mina_graphql.Types.Input

    module Unlock_account =
    [%graphql
    ({|
      mutation ($password: String!, $public_key: PublicKey!) @encoders(module: "Encoders"){
        unlockAccount(input: {password: $password, publicKey: $public_key }) {
          account {
            public_key: publicKey
          }
        }
      }
    |}
    [@encoders Encoders] )]

    module Send_test_payments =
    [%graphql
    {|
      mutation ($senders: [PrivateKey!]!,
      $receiver: PublicKey!,
      $amount: UInt64!,
      $fee: UInt64!,
      $repeat_count: UInt32!,
      $repeat_delay_ms: UInt32!) @encoders(module: "Encoders"){
        sendTestPayments(
          senders: $senders, receiver: $receiver, amount: $amount, fee: $fee,
          repeat_count: $repeat_count,
          repeat_delay_ms: $repeat_delay_ms)
      }
    |}]

    module Send_payment =
    [%graphql
    {|
     mutation ($input: SendPaymentInput!)@encoders(module: "Encoders"){
        sendPayment(input: $input){
            payment {
              id
              nonce
              hash
            }
          }
      }
    |}]

    module Send_payment_with_raw_sig =
    [%graphql
    {|
     mutation (
     $input:SendPaymentInput!,
     $rawSignature: String!
     )@encoders(module: "Encoders")
      {
        sendPayment(
          input:$input,
          signature: {rawSignature: $rawSignature}
        )
        {
          payment {
            id
            nonce
            hash
          }
        }
      }
    |}]

    module Send_delegation =
    [%graphql
    {|
      mutation ($input: SendDelegationInput!) @encoders(module: "Encoders"){
        sendDelegation(input:$input){
            delegation {
              id
              nonce
              hash
            }
          }
      }
    |}]

    module Set_snark_worker =
    [%graphql
    {|
      mutation ($input: SetSnarkWorkerInput! ) @encoders(module: "Encoders"){
        setSnarkWorker(input:$input){
          lastSnarkWorker
          }
      }
    |}]

    module Get_account_data =
    [%graphql
    {|
      query ($public_key: PublicKey!) @encoders(module: "Encoders"){
        account(publicKey: $public_key) {
          nonce
          balance {
            total @ppxCustom(module: "Scalars.Balance")
          }
        }
      }
    |}]

    (* TODO: temporary version *)
    module Send_test_zkapp = Generated_graphql_queries.Send_test_zkapp
    module Pooled_zkapp_commands =
      Generated_graphql_queries.Pooled_zkapp_commands

    module Query_peer_id =
    [%graphql
    {|
      query {
        daemonStatus {
          addrsAndPorts {
            peer {
              peerId
            }
          }
          peers {  peerId }

        }
      }
    |}]

    module Best_chain =
    [%graphql
    {|
      query ($max_length: Int) @encoders(module: "Encoders"){
        bestChain (maxLength: $max_length) {
          stateHash @ppxCustom(module: "Graphql_lib.Scalars.String_json")
          commandTransactionCount
          creatorAccount {
            publicKey @ppxCustom(module: "Graphql_lib.Scalars.JSON")
          }
        }
      }
    |}]

    module Query_metrics =
    [%graphql
    {|
      query {
        daemonStatus {
          metrics {
            blockProductionDelay
            transactionPoolDiffReceived
            transactionPoolDiffBroadcasted
            transactionsAddedToPool
            transactionPoolSize
          }
        }
      }
    |}]

    module StartFilteredLog =
    [%graphql
    {|
      mutation ($filter: [String!]!) @encoders(module: "Encoders"){
        startFilteredLog(filter: $filter)
      }
    |}]

    module GetFilteredLogEntries =
    [%graphql
    {|
      query ($offset: Int!) @encoders(module: "Encoders"){
        getFilteredLogEntries(offset: $offset) {
            logMessages,
            isCapturing,
        }

    }
    |}]

    module Account =
    [%graphql
    {|
      query ($public_key: PublicKey!, $token: UInt64) {
        account (publicKey : $public_key, token : $token) {
          balance { liquid
                    locked
                    total
                  }
          delegate
          nonce
          permissions { editActionState
                        editState
                        incrementNonce
                        receive
                        send
                        access
                        setDelegate
                        setPermissions
                        setZkappUri
                        setTokenSymbol
                        setVerificationKey
                        setVotingFor
                        setTiming
                      }
          actionState
          zkappState
          zkappUri
          timing { cliffTime @ppxCustom(module: "Graphql_lib.Scalars.JSON")
                   cliffAmount
                   vestingPeriod @ppxCustom(module: "Graphql_lib.Scalars.JSON")
                   vestingIncrement
                   initialMinimumBalance
                 }
          tokenId
          tokenSymbol
          verificationKey { verificationKey
                            hash
                          }
          votingFor
        }
      }
    |}]
  end

  (* this function will repeatedly attempt to connect to graphql port <num_tries> times before giving up *)
  let exec_graphql_request ?(num_tries = 10) ?(retry_delay_sec = 30.0)
      ?(initial_delay_sec = 0.) ~logger ~node ~query_name query_obj =
    let open Deferred.Let_syntax in
    if not node.config.graphql_enabled then
      Deferred.Or_error.error_string
        "graphql is not enabled (hint: set `requires_graphql= true` in the \
         test config)"
    else
      let uri = Graphql.ingress_uri node in
      let metadata =
        [ ("query", `String query_name)
        ; ("uri", `String (Uri.to_string uri))
        ; ("init_delay", `Float initial_delay_sec)
        ]
      in
      [%log info]
        "Attempting to send GraphQL request \"$query\" to \"$uri\" after \
         $init_delay sec"
        ~metadata ;
      let rec retry n =
        if n <= 0 then (
          [%log error]
            "GraphQL request \"$query\" to \"$uri\" failed too many times"
            ~metadata ;
          Deferred.Or_error.errorf
            "GraphQL \"%s\" to \"%s\" request failed too many times" query_name
            (Uri.to_string uri) )
        else
          match%bind Graphql.Client.query query_obj uri with
          | Ok result ->
              [%log info] "GraphQL request \"$query\" to \"$uri\" succeeded"
                ~metadata ;
              Deferred.Or_error.return result
          | Error (`Failed_request err_string) ->
              [%log warn]
                "GraphQL request \"$query\" to \"$uri\" failed: \"$error\" \
                 ($num_tries attempts left)"
                ~metadata:
                  ( metadata
                  @ [ ("error", `String err_string)
                    ; ("num_tries", `Int (n - 1))
                    ] ) ;
              let%bind () = after (Time.Span.of_sec retry_delay_sec) in
              retry (n - 1)
          | Error (`Graphql_error err_string) ->
              [%log error]
                "GraphQL request \"$query\" to \"$uri\" returned an error: \
                 \"$error\" (this is a graphql error so not retrying)"
                ~metadata:(metadata @ [ ("error", `String err_string) ]) ;
              Deferred.Or_error.error_string err_string
      in
      let%bind () = after (Time.Span.of_sec initial_delay_sec) in
      retry num_tries

  let get_peer_id ~logger t =
    let open Deferred.Or_error.Let_syntax in
    [%log info] "Getting node's peer_id, and the peer_ids of node's peers"
      ~metadata:(logger_metadata t) ;
    let query_obj = Graphql.Query_peer_id.(make @@ makeVariables ()) in
    let%bind query_result_obj =
      exec_graphql_request ~logger ~node:t ~query_name:"query_peer_id" query_obj
    in
    [%log info] "get_peer_id, finished exec_graphql_request" ;
    let self_id_obj = query_result_obj.daemonStatus.addrsAndPorts.peer in
    let%bind self_id =
      match self_id_obj with
      | None ->
          Deferred.Or_error.error_string "Peer not found"
      | Some peer ->
          return peer.peerId
    in
    let peers = query_result_obj.daemonStatus.peers |> Array.to_list in
    let peer_ids = List.map peers ~f:(fun peer -> peer.peerId) in
    [%log info] "get_peer_id, result of graphql query (self_id,[peers]) (%s,%s)"
      self_id
      (String.concat ~sep:" " peer_ids) ;
    return (self_id, peer_ids)

  let must_get_peer_id ~logger t =
    get_peer_id ~logger t |> Deferred.bind ~f:Malleable_error.or_hard_error

  let get_best_chain ?max_length ~logger t =
    let open Deferred.Or_error.Let_syntax in
    let query = Graphql.Best_chain.(make @@ makeVariables ?max_length ()) in
    let%bind result =
      exec_graphql_request ~logger ~node:t ~query_name:"best_chain" query
    in
    match result.bestChain with
    | None | Some [||] ->
        Deferred.Or_error.error_string "failed to get best chains"
    | Some chain ->
        return
        @@ List.map
             ~f:(fun block ->
               Intf.
                 { state_hash = block.stateHash
                 ; command_transaction_count = block.commandTransactionCount
                 ; creator_pk =
                     ( match block.creatorAccount.publicKey with
                     | `String pk ->
                         pk
                     | _ ->
                         "unknown" )
                 } )
             (Array.to_list chain)

  let must_get_best_chain ?max_length ~logger t =
    get_best_chain ?max_length ~logger t
    |> Deferred.bind ~f:Malleable_error.or_hard_error

  let get_account ~logger t ~account_id =
    let pk = Mina_base.Account_id.public_key account_id in
    let token = Mina_base.Account_id.token_id account_id in
    [%log info] "Getting account"
      ~metadata:
        ( ("pub_key", Signature_lib.Public_key.Compressed.to_yojson pk)
        :: logger_metadata t ) ;
    let get_account_obj =
      Graphql.Account.(
        make
        @@ makeVariables
             ~public_key:(Graphql_lib.Encoders.public_key pk)
             ~token:(Graphql_lib.Encoders.token token)
             ())
    in
    exec_graphql_request ~logger ~node:t ~query_name:"get_account_graphql"
      get_account_obj

  type account_data =
    { nonce : Mina_numbers.Account_nonce.t
    ; total_balance : Currency.Balance.t
    ; liquid_balance_opt : Currency.Balance.t option
    ; locked_balance_opt : Currency.Balance.t option
    }

  let get_account_data ~logger t ~account_id =
    let open Deferred.Or_error.Let_syntax in
    let public_key = Mina_base.Account_id.public_key account_id in
    let token = Mina_base.Account_id.token_id account_id in
    [%log info] "Getting account data, which is its balances and nonce"
      ~metadata:
        ( ("pub_key", Signature_lib.Public_key.Compressed.to_yojson public_key)
        :: logger_metadata t ) ;
    let%bind account_obj = get_account ~logger t ~account_id in
    match account_obj.account with
    | None ->
        Deferred.Or_error.errorf
          !"Account with Account id %{sexp:Mina_base.Account_id.t}, public_key \
            %s, and token %s not found"
          account_id
          (Signature_lib.Public_key.Compressed.to_string public_key)
          (Mina_base.Token_id.to_string token)
    | Some acc ->
        return
          { nonce =
              Option.value_exn
                ~message:
                  "the nonce from get_balance is None, which should be \
                   impossible"
                acc.nonce
          ; total_balance = acc.balance.total
          ; liquid_balance_opt = acc.balance.liquid
          ; locked_balance_opt = acc.balance.locked
          }

  let must_get_account_data ~logger t ~account_id =
    get_account_data ~logger t ~account_id
    |> Deferred.bind ~f:Malleable_error.or_hard_error

  let permissions_of_account_permissions account_permissions :
      Mina_base.Permissions.t =
    (* the polymorphic variants come from Partial_accounts.auth_required in Mina_graphql *)
    let to_auth_required = function
      | `Either ->
          Mina_base.Permissions.Auth_required.Either
      | `Impossible ->
          Impossible
      | `None ->
          None
      | `Proof ->
          Proof
      | `Signature ->
          Signature
    in
    let open Graphql.Account in
    { edit_action_state = to_auth_required account_permissions.editActionState
    ; edit_state = to_auth_required account_permissions.editState
    ; increment_nonce = to_auth_required account_permissions.incrementNonce
    ; receive = to_auth_required account_permissions.receive
    ; send = to_auth_required account_permissions.send
    ; access = to_auth_required account_permissions.access
    ; set_delegate = to_auth_required account_permissions.setDelegate
    ; set_permissions = to_auth_required account_permissions.setPermissions
    ; set_zkapp_uri = to_auth_required account_permissions.setZkappUri
    ; set_token_symbol = to_auth_required account_permissions.setTokenSymbol
    ; set_verification_key =
        to_auth_required account_permissions.setVerificationKey
    ; set_voting_for = to_auth_required account_permissions.setVotingFor
    ; set_timing = to_auth_required account_permissions.setTiming
    }

  let graphql_uri node = Graphql.ingress_uri node |> Uri.to_string

  let get_account_permissions ~logger t ~account_id =
    let open Deferred.Or_error in
    let open Let_syntax in
    let%bind account_obj = get_account ~logger t ~account_id in
    match account_obj.account with
    | Some account -> (
        match account.permissions with
        | Some ledger_permissions ->
            return @@ permissions_of_account_permissions ledger_permissions
        | None ->
            fail
              (Error.of_string "Could not get permissions from ledger account")
        )
    | None ->
        fail (Error.of_string "Could not get account from ledger")

  (* return a Account_update.Update.t with all fields `Set` to the
     value in the account, or `Keep` if value unavailable,
     as if this update had been applied to the account
  *)
  let get_account_update ~logger t ~account_id =
    let open Deferred.Or_error in
    let open Let_syntax in
    let%bind account_obj = get_account ~logger t ~account_id in
    match account_obj.account with
    | Some account ->
        let open Mina_base.Zkapp_basic.Set_or_keep in
        let%bind app_state =
          match account.zkappState with
          | Some strs ->
              let fields =
                Array.to_list strs |> Base.List.map ~f:(fun s -> Set s)
              in
              return (Mina_base.Zkapp_state.V.of_list_exn fields)
          | None ->
              fail
                (Error.of_string
                   (sprintf
                      "Expected zkApp account with an app state for public key \
                       %s"
                      (Signature_lib.Public_key.Compressed.to_base58_check
                         (Mina_base.Account_id.public_key account_id) ) ) )
        in
        let%bind delegate =
          match account.delegate with
          | Some s ->
              return (Set s)
          | None ->
              fail (Error.of_string "Expected delegate in account")
        in
        let%bind verification_key =
          match account.verificationKey with
          | Some vk_obj ->
              let data = vk_obj.verificationKey in
              let hash = vk_obj.hash in
              return (Set ({ data; hash } : _ With_hash.t))
          | None ->
              fail
                (Error.of_string
                   (sprintf
                      "Expected zkApp account with a verification key for \
                       public_key %s"
                      (Signature_lib.Public_key.Compressed.to_base58_check
                         (Mina_base.Account_id.public_key account_id) ) ) )
        in
        let%bind permissions =
          match account.permissions with
          | Some perms ->
              return @@ Set (permissions_of_account_permissions perms)
          | None ->
              fail (Error.of_string "Expected permissions in account")
        in
        let%bind zkapp_uri =
          match account.zkappUri with
          | Some s ->
              return @@ Set s
          | None ->
              fail (Error.of_string "Expected zkApp URI in account")
        in
        let%bind token_symbol =
          match account.tokenSymbol with
          | Some s ->
              return @@ Set s
          | None ->
              fail (Error.of_string "Expected token symbol in account")
        in
        let%bind timing =
          let timing = account.timing in
          let cliff_amount = timing.cliffAmount in
          let cliff_time = timing.cliffTime in
          let vesting_period = timing.vestingPeriod in
          let vesting_increment = timing.vestingIncrement in
          let initial_minimum_balance = timing.initialMinimumBalance in
          match
            ( cliff_amount
            , cliff_time
            , vesting_period
            , vesting_increment
            , initial_minimum_balance )
          with
          | None, None, None, None, None ->
              return @@ Keep
          | Some amt, Some tm, Some period, Some incr, Some bal ->
              let cliff_amount = amt in
              let%bind cliff_time =
                match tm with
                | `String s ->
                    return @@ Mina_numbers.Global_slot_since_genesis.of_string s
                | _ ->
                    fail
                      (Error.of_string
                         "Expected string for cliff time in account timing" )
              in
              let%bind vesting_period =
                match period with
                | `String s ->
                    return @@ Mina_numbers.Global_slot_span.of_string s
                | _ ->
                    fail
                      (Error.of_string
                         "Expected string for vesting period in account timing" )
              in
              let vesting_increment = incr in
              let initial_minimum_balance = bal in
              return
                (Set
                   ( { initial_minimum_balance
                     ; cliff_amount
                     ; cliff_time
                     ; vesting_period
                     ; vesting_increment
                     }
                     : Mina_base.Account_update.Update.Timing_info.t ) )
          | _ ->
              fail (Error.of_string "Some pieces of account timing are missing")
        in
        let%bind voting_for =
          match account.votingFor with
          | Some s ->
              return @@ Set s
          | None ->
              fail (Error.of_string "Expected voting-for state hash in account")
        in
        return
          ( { app_state
            ; delegate
            ; verification_key
            ; permissions
            ; zkapp_uri
            ; token_symbol
            ; timing
            ; voting_for
            }
            : Mina_base.Account_update.Update.t )
    | None ->
        fail (Error.of_string "Could not get account from ledger")

  type signed_command_result =
    { id : string
    ; hash : Transaction_hash.t
    ; nonce : Mina_numbers.Account_nonce.t
    }

  let transaction_id_to_string id =
    Yojson.Basic.to_string (Graphql_lib.Scalars.TransactionId.serialize id)

  (* if we expect failure, might want retry_on_graphql_error to be false *)
  let send_payment ~logger t ~sender_pub_key ~receiver_pub_key ~amount ~fee =
    [%log info] "Sending a payment" ~metadata:(logger_metadata t) ;
    let open Deferred.Or_error.Let_syntax in
    let sender_pk_str =
      Signature_lib.Public_key.Compressed.to_string sender_pub_key
    in
    [%log info] "send_payment: unlocking account"
      ~metadata:[ ("sender_pk", `String sender_pk_str) ] ;
    let unlock_sender_account_graphql () =
      let unlock_account_obj =
        Graphql.Unlock_account.(
          make
          @@ makeVariables ~password:node_password ~public_key:sender_pub_key ())
      in
      exec_graphql_request ~logger ~node:t ~initial_delay_sec:0.
        ~query_name:"unlock_sender_account_graphql" unlock_account_obj
    in
    let%bind _unlock_acct_obj = unlock_sender_account_graphql () in
    let send_payment_graphql () =
      let input =
        Mina_graphql.Types.Input.SendPaymentInput.make_input
          ~from:sender_pub_key ~to_:receiver_pub_key ~amount ~fee ()
      in
      let send_payment_obj =
        Graphql.Send_payment.(make @@ makeVariables ~input ())
      in
      exec_graphql_request ~logger ~node:t ~query_name:"send_payment_graphql"
        send_payment_obj
    in
    let%map sent_payment_obj = send_payment_graphql () in
    let return_obj = sent_payment_obj.sendPayment.payment in
    let res =
      { id = transaction_id_to_string return_obj.id
      ; hash = return_obj.hash
      ; nonce = Mina_numbers.Account_nonce.of_int return_obj.nonce
      }
    in
    [%log info] "Sent payment"
      ~metadata:
        [ ("user_command_id", `String res.id)
        ; ("hash", `String (Transaction_hash.to_base58_check res.hash))
        ; ("nonce", `Int (Mina_numbers.Account_nonce.to_int res.nonce))
        ] ;
    res

  let must_send_payment ~logger t ~sender_pub_key ~receiver_pub_key ~amount ~fee
      =
    send_payment ~logger t ~sender_pub_key ~receiver_pub_key ~amount ~fee
    |> Deferred.bind ~f:Malleable_error.or_hard_error

  let send_zkapp_batch ~logger (t : t)
      ~(zkapp_commands : Mina_base.Zkapp_command.t list) =
    [%log info] "Sending zkapp transactions"
      ~metadata:
        [ ("namespace", `String t.config.namespace)
        ; ("pod_id", `String (id t))
        ] ;
    let open Deferred.Or_error.Let_syntax in
    let zkapp_commands_json =
      List.map zkapp_commands ~f:(fun zkapp_command ->
          Mina_base.Zkapp_command.to_json zkapp_command |> Yojson.Safe.to_basic )
      |> Array.of_list
    in
    let send_zkapp_graphql () =
      let send_zkapp_obj =
        Graphql.Send_test_zkapp.(
          make @@ makeVariables ~zkapp_commands:zkapp_commands_json ())
      in
      exec_graphql_request ~logger ~node:t ~query_name:"send_zkapp_graphql"
        send_zkapp_obj
    in
    let%bind sent_zkapp_obj = send_zkapp_graphql () in
    let%bind zkapp_ids =
      Deferred.Array.fold ~init:(Ok []) sent_zkapp_obj.internalSendZkapp
        ~f:(fun acc (zkapp_obj : Graphql.Send_test_zkapp.t_internalSendZkapp) ->
          let%bind res =
            match zkapp_obj.zkapp.failureReason with
            | None ->
                let zkapp_id = transaction_id_to_string zkapp_obj.zkapp.id in
                [%log info] "Sent zkapp transaction"
                  ~metadata:[ ("zkapp_id", `String zkapp_id) ] ;
                return zkapp_id
            | Some s ->
                Deferred.Or_error.errorf "Zkapp failed, reason: %s"
                  ( Array.fold ~init:[] s ~f:(fun acc f ->
                        match f with
                        | None ->
                            acc
                        | Some f ->
                            let t =
                              ( Option.value_exn f.index
                              , f.failures |> Array.to_list |> List.rev )
                            in
                            t :: acc )
                  |> Mina_base.Transaction_status.Failure.Collection.Display
                     .to_yojson |> Yojson.Safe.to_string )
          in
          let%map acc = Deferred.return acc in
          res :: acc )
    in
    return (List.rev zkapp_ids)

  let get_pooled_zkapp_commands ~logger (t : t)
      ~(pk : Signature_lib.Public_key.Compressed.t) =
    [%log info] "Retrieving zkapp_commands from transaction pool"
      ~metadata:
        [ ("namespace", `String t.config.namespace)
        ; ("pod_id", `String (id t))
        ; ("pub_key", Signature_lib.Public_key.Compressed.to_yojson pk)
        ] ;
    let open Deferred.Or_error.Let_syntax in
    let get_pooled_zkapp_commands_graphql () =
      let get_pooled_zkapp_commands =
        Graphql.Pooled_zkapp_commands.(
          make
          @@ makeVariables ~public_key:(Graphql_lib.Encoders.public_key pk) ())
      in
      exec_graphql_request ~logger ~node:t
        ~query_name:"get_pooled_zkapp_commands" get_pooled_zkapp_commands
    in
    let%bind zkapp_pool_obj = get_pooled_zkapp_commands_graphql () in
    let transaction_ids =
      Array.map zkapp_pool_obj.pooledZkappCommands ~f:(fun zkapp_command ->
          zkapp_command.id |> Transaction_id.to_base64 )
      |> Array.to_list
    in
    [%log info] "Retrieved zkapp_commands from transaction pool"
      ~metadata:
        [ ("namespace", `String t.config.namespace)
        ; ("pod_id", `String (id t))
        ; ( "transaction ids"
          , `List (List.map ~f:(fun t -> `String t) transaction_ids) )
        ] ;
    return transaction_ids

  let send_delegation ~logger t ~sender_pub_key ~receiver_pub_key ~fee =
    [%log info] "Sending stake delegation" ~metadata:(logger_metadata t) ;
    let open Deferred.Or_error.Let_syntax in
    let sender_pk_str =
      Signature_lib.Public_key.Compressed.to_string sender_pub_key
    in
    [%log info] "send_delegation: unlocking account"
      ~metadata:[ ("sender_pk", `String sender_pk_str) ] ;
    let unlock_sender_account_graphql () =
      let unlock_account_obj =
        Graphql.Unlock_account.(
          make
          @@ makeVariables ~password:"naughty blue worm"
               ~public_key:sender_pub_key ())
      in
      exec_graphql_request ~logger ~node:t
        ~query_name:"unlock_sender_account_graphql" unlock_account_obj
    in
    let%bind _ = unlock_sender_account_graphql () in
    let send_delegation_graphql () =
      let input =
        Mina_graphql.Types.Input.SendDelegationInput.make_input
          ~from:sender_pub_key ~to_:receiver_pub_key ~fee ()
      in
      let send_delegation_obj =
        Graphql.Send_delegation.(make @@ makeVariables ~input ())
      in
      exec_graphql_request ~logger ~node:t ~query_name:"send_delegation_graphql"
        send_delegation_obj
    in
    let%map result_obj = send_delegation_graphql () in
    let return_obj = result_obj.sendDelegation.delegation in
    let res =
      { id = transaction_id_to_string return_obj.id
      ; hash = return_obj.hash
      ; nonce = Mina_numbers.Account_nonce.of_int return_obj.nonce
      }
    in
    [%log info] "stake delegation sent"
      ~metadata:
        [ ("user_command_id", `String res.id)
        ; ("hash", `String (Transaction_hash.to_base58_check res.hash))
        ; ("nonce", `Int (Mina_numbers.Account_nonce.to_int res.nonce))
        ] ;
    res

  let must_send_delegation ~logger t ~sender_pub_key ~receiver_pub_key ~fee =
    send_delegation ~logger t ~sender_pub_key ~receiver_pub_key ~fee
    |> Deferred.bind ~f:Malleable_error.or_hard_error

  let send_payment_with_raw_sig ~logger t ~sender_pub_key ~receiver_pub_key
      ~amount ~fee ~nonce ~memo
      ~(valid_until : Mina_numbers.Global_slot_since_genesis.t) ~raw_signature =
    [%log info] "Sending a payment with raw signature"
      ~metadata:(logger_metadata t) ;
    let open Deferred.Or_error.Let_syntax in
    let send_payment_graphql () =
      let open Graphql.Send_payment_with_raw_sig in
      let input =
        Mina_graphql.Types.Input.SendPaymentInput.make_input
          ~from:sender_pub_key ~to_:receiver_pub_key ~amount ~fee ~memo ~nonce
          ~valid_until:
            (Mina_numbers.Global_slot_since_genesis.to_uint32 valid_until)
          ()
      in
      let variables = makeVariables ~input ~rawSignature:raw_signature () in
      let send_payment_obj = make variables in
      let variables_json_basic =
        variablesToJson (serializeVariables variables)
      in
      (* An awkward conversion from Yojson.Basic to Yojson.Safe *)
      let variables_json =
        Yojson.Basic.to_string variables_json_basic |> Yojson.Safe.from_string
      in
      [%log info] "send_payment_obj with $variables "
        ~metadata:[ ("variables", variables_json) ] ;
      exec_graphql_request ~logger ~node:t
        ~query_name:"Send_payment_with_raw_sig_graphql" send_payment_obj
    in
    let%map sent_payment_obj = send_payment_graphql () in
    let return_obj = sent_payment_obj.sendPayment.payment in
    let res =
      { id = transaction_id_to_string return_obj.id
      ; hash = return_obj.hash
      ; nonce = Mina_numbers.Account_nonce.of_int return_obj.nonce
      }
    in
    [%log info] "Sent payment"
      ~metadata:
        [ ("user_command_id", `String res.id)
        ; ("hash", `String (Transaction_hash.to_base58_check res.hash))
        ; ("nonce", `Int (Mina_numbers.Account_nonce.to_int res.nonce))
        ] ;
    res

  let must_send_payment_with_raw_sig ~logger t ~sender_pub_key ~receiver_pub_key
      ~amount ~fee ~nonce ~memo ~valid_until ~raw_signature =
    send_payment_with_raw_sig ~logger t ~sender_pub_key ~receiver_pub_key
      ~amount ~fee ~nonce ~memo ~valid_until ~raw_signature
    |> Deferred.bind ~f:Malleable_error.or_hard_error

  let send_test_payments ~repeat_count ~repeat_delay_ms ~logger t ~senders
      ~receiver_pub_key ~amount ~fee =
    [%log info] "Sending a series of test payments"
      ~metadata:(logger_metadata t) ;
    let open Deferred.Or_error.Let_syntax in
    let send_payment_graphql () =
      let send_payment_obj =
        Graphql.Send_test_payments.(
          make
          @@ makeVariables ~senders ~receiver:receiver_pub_key
               ~amount:(Currency.Amount.to_uint64 amount)
               ~fee:(Currency.Fee.to_uint64 fee)
               ~repeat_count ~repeat_delay_ms ())
      in
      exec_graphql_request ~logger ~node:t ~query_name:"send_payment_graphql"
        send_payment_obj
    in
    let%map _ = send_payment_graphql () in
    [%log info] "Sent test payments"

  let must_send_test_payments ~repeat_count ~repeat_delay_ms ~logger t ~senders
      ~receiver_pub_key ~amount ~fee =
    send_test_payments ~repeat_count ~repeat_delay_ms ~logger t ~senders
      ~receiver_pub_key ~amount ~fee
    |> Deferred.bind ~f:Malleable_error.or_hard_error

  let set_snark_worker ~logger t ~new_snark_pub_key =
    [%log info] "Changing snark worker key" ~metadata:(logger_metadata t) ;
    let open Deferred.Or_error.Let_syntax in
    let set_snark_worker_graphql () =
      let input = Some new_snark_pub_key in
      let set_snark_worker_obj =
        Graphql.Set_snark_worker.(make @@ makeVariables ~input ())
      in
      exec_graphql_request ~logger ~node:t
        ~query_name:"set_snark_worker_graphql" set_snark_worker_obj
    in
    let%map result_obj = set_snark_worker_graphql () in
    let returned_last_snark_worker_opt =
      result_obj.setSnarkWorker.lastSnarkWorker
    in
    let last_snark_worker =
      match returned_last_snark_worker_opt with
      | None ->
          "<no last snark worker>"
      | Some last ->
          last |> Scalars.PublicKey.serialize |> Yojson.Basic.to_string
    in
    [%log info] "snark worker changed, lastSnarkWorker: %s" last_snark_worker
      ~metadata:[ ("lastSnarkWorker", `String last_snark_worker) ] ;
    ()

  let must_set_snark_worker ~logger t ~new_snark_pub_key =
    set_snark_worker ~logger t ~new_snark_pub_key
    |> Deferred.bind ~f:Malleable_error.or_hard_error

  let start_filtered_log ~logger ~log_filter t =
    let open Deferred.Let_syntax in
    let query_obj =
      Graphql.StartFilteredLog.(make @@ makeVariables ~filter:log_filter ())
    in
    let%bind res =
      exec_graphql_request ~logger:(Logger.null ()) ~retry_delay_sec:10.0
        ~node:t ~query_name:"StartFilteredLog" query_obj
    in
    match res with
    | Ok query_result_obj ->
        let had_already_started = query_result_obj.startFilteredLog in
        if had_already_started then return (Ok ())
        else (
          [%log error]
            "Attempted to start structured log collection on $node, but it had \
             already started"
            ~metadata:[ ("node", `String t.app_id) ] ;
          (* TODO: If this is common, figure out what to do *)
          return (Ok ()) )
    | Error e ->
        return (Error e)

  let get_filtered_log_entries ~last_log_index_seen t =
    let open Deferred.Or_error.Let_syntax in
    let query_obj =
      Graphql.GetFilteredLogEntries.(
        make @@ makeVariables ~offset:last_log_index_seen ())
    in
    let%bind query_result_obj =
      exec_graphql_request ~logger:(Logger.null ()) ~retry_delay_sec:10.0
        ~node:t ~query_name:"GetFilteredLogEntries" query_obj
    in
    let res = query_result_obj.getFilteredLogEntries in
    if res.isCapturing then return res.logMessages
    else
      Deferred.Or_error.error_string
        "Node is not currently capturing structured log messages"

  let dump_archive_data ~logger (t : t) ~data_file =
    (* this function won't work if `t` doesn't happen to be an archive node *)
    if not t.pod_info.has_archive_container then
      failwith
        "No archive container found.  One can only dump archive data of an \
         archive node." ;
    let open Malleable_error.Let_syntax in
    let postgresql_pod_id = t.app_id ^ "-postgresql-0" in
    let postgresql_container_id = "postgresql" in
    (* Some quick clarification on the archive nodes:
         An archive node archives all blocks as they come through, but does not produce blocks.
         An archive node uses postgresql as storage, the postgresql db needs to be separately brought up and is sort of it's own thing infra wise
         Archive nodes can be run side-by-side with an actual mina node

       in the integration test framework, every archive node will have it's own single postgresql instance.
       thus in the integration testing framework there will always be a one to one correspondence between archive node and postgresql db.
       however more generally, it's entirely possible for a mina user/operator set up multiple archive nodes to be backed by a single postgresql database.
       But for now we will assume that we don't need to test that

       The integration test framework creates kubenetes deployments or "workloads" as they are called in GKE, but Nodes are mainly tracked by pod_id

       A postgresql workload in the integration test framework will always have 1 managed pod,
         whose pod_id is simply the app id/workload name of the archive node appended with "-postgresql-0".
         so if the archive node is called "archive-1", then the corresponding postgresql managed pod will be called "archive-1-postgresql-0".
       That managed pod will have exactly 1 container, and it will be called simply "postgresql"

       It's rather hardcoded but this was just the simplest way to go, as our kubernetes_network tracks Nodes, ie MINA nodes.  a postgresql db is hard to account for
       It's possible to run pg_dump from the archive node instead of directly reaching out to the postgresql pod, and that's what we used to do but there were occasionally version mismatches between the pg_dump on the archive node and the postgresql on the postgresql db
    *)
    [%log info] "Dumping archive data from (node: %s, container: %s)"
      postgresql_pod_id postgresql_container_id ;
    let%map data =
      run_in_container t ~container_id:postgresql_container_id
        ~override_with_pod_id:postgresql_pod_id
        ~cmd:[ "pg_dump"; "--create"; "--no-owner"; postgres_url ]
    in
    [%log info] "Dumping archive data to file %s" data_file ;
    Out_channel.with_file data_file ~f:(fun out_ch ->
        Out_channel.output_string out_ch data )

  let run_replayer ~logger (t : t) =
    [%log info] "Running replayer on archived data (node: %s, container: %s)"
      (List.hd_exn t.pod_ids) mina_archive_container_id ;
    let open Malleable_error.Let_syntax in
    let%bind accounts =
      run_in_container t
        ~cmd:[ "jq"; "-c"; ".ledger.accounts"; "/root/config/daemon.json" ]
    in
    let replayer_input =
      sprintf
        {| { "genesis_ledger": { "accounts": %s, "add_genesis_winner": true }} |}
        accounts
    in
    let dest = "replayer-input.json" in
    let%bind _res =
      Deferred.bind ~f:Malleable_error.return
        (cp_string_to_container_file t ~container_id:mina_archive_container_id
           ~str:replayer_input ~dest )
    in
    run_in_container t ~container_id:mina_archive_container_id
      ~cmd:
        [ "mina-replayer"
        ; "--archive-uri"
        ; postgres_url
        ; "--input-file"
        ; dest
        ; "--output-file"
        ; "/dev/null"
        ; "--continue-on-error"
        ]

  let dump_mina_logs ~logger (t : t) ~log_file =
    let open Malleable_error.Let_syntax in
    [%log info] "Dumping container logs from (node: %s, container: %s)"
      (List.hd_exn t.pod_ids) t.pod_info.primary_container_id ;
    let%map logs = get_logs_in_container t in
    [%log info] "Dumping container log to file %s" log_file ;
    Out_channel.with_file log_file ~f:(fun out_ch ->
        Out_channel.output_string out_ch logs )

  let dump_precomputed_blocks ~logger (t : t) =
    let open Malleable_error.Let_syntax in
    [%log info]
      "Dumping precomputed blocks from logs for (node: %s, container: %s)"
      (List.hd_exn t.pod_ids) t.pod_info.primary_container_id ;
    let%bind logs = get_logs_in_container t in
    (* kubectl logs may include non-log output, like "Using password from environment variable" *)
    let log_lines =
      String.split logs ~on:'\n'
      |> List.filter ~f:(String.is_prefix ~prefix:"{\"timestamp\":")
    in
    let jsons = List.map log_lines ~f:Yojson.Safe.from_string in
    let metadata_jsons =
      List.map jsons ~f:(fun json ->
          match json with
          | `Assoc items -> (
              match List.Assoc.find items ~equal:String.equal "metadata" with
              | Some md ->
                  md
              | None ->
                  failwithf "Log line is missing metadata: %s"
                    (Yojson.Safe.to_string json)
                    () )
          | other ->
              failwithf "Expected log line to be a JSON record, got: %s"
                (Yojson.Safe.to_string other)
                () )
    in
    let state_hash_and_blocks =
      List.fold metadata_jsons ~init:[] ~f:(fun acc json ->
          match json with
          | `Assoc items -> (
              match
                List.Assoc.find items ~equal:String.equal "precomputed_block"
              with
              | Some block -> (
                  match
                    List.Assoc.find items ~equal:String.equal "state_hash"
                  with
                  | Some state_hash ->
                      (state_hash, block) :: acc
                  | None ->
                      failwith
                        "Log metadata contains a precomputed block, but no \
                         state hash" )
              | None ->
                  acc )
          | other ->
              failwithf "Expected log line to be a JSON record, got: %s"
                (Yojson.Safe.to_string other)
                () )
    in
    let%bind.Deferred () =
      Deferred.List.iter state_hash_and_blocks
        ~f:(fun (state_hash_json, block_json) ->
          let double_quoted_state_hash =
            Yojson.Safe.to_string state_hash_json
          in
          let state_hash =
            String.sub double_quoted_state_hash ~pos:1
              ~len:(String.length double_quoted_state_hash - 2)
          in
          let block = Yojson.Safe.pretty_to_string block_json in
          let filename = state_hash ^ ".json" in
          match%map.Deferred Sys.file_exists filename with
          | `Yes ->
              [%log info]
                "File already exists for precomputed block with state hash %s"
                state_hash
          | _ ->
              [%log info]
                "Dumping precomputed block with state hash %s to file %s"
                state_hash filename ;
              Out_channel.with_file filename ~f:(fun out_ch ->
                  Out_channel.output_string out_ch block ) )
    in
    Malleable_error.return ()

  let get_metrics ~logger t =
    let open Deferred.Or_error.Let_syntax in
    [%log info] "Getting node's metrics" ~metadata:(logger_metadata t) ;
    let query_obj = Graphql.Query_metrics.make () in
    let%bind query_result_obj =
      exec_graphql_request ~logger ~node:t ~query_name:"query_metrics" query_obj
    in
    [%log info] "get_metrics, finished exec_graphql_request" ;
    let block_production_delay =
      Array.to_list
      @@ query_result_obj.daemonStatus.metrics.blockProductionDelay
    in
    let metrics = query_result_obj.daemonStatus.metrics in
    let transaction_pool_diff_received = metrics.transactionPoolDiffReceived in
    let transaction_pool_diff_broadcasted =
      metrics.transactionPoolDiffBroadcasted
    in
    let transactions_added_to_pool = metrics.transactionsAddedToPool in
    let transaction_pool_size = metrics.transactionPoolSize in
    [%log info]
      "get_metrics, result of graphql query (block_production_delay; \
       tx_received; tx_broadcasted; txs_added_to_pool; tx_pool_size) (%s; %d; \
       %d; %d; %d)"
      ( String.concat ~sep:", "
      @@ List.map ~f:string_of_int block_production_delay )
      transaction_pool_diff_received transaction_pool_diff_broadcasted
      transactions_added_to_pool transaction_pool_size ;
    return
      Intf.
        { block_production_delay
        ; transaction_pool_diff_broadcasted
        ; transaction_pool_diff_received
        ; transactions_added_to_pool
        ; transaction_pool_size
        }
end

module Workload_to_deploy = struct
  type t = { workload_id : string; pod_info : Node.pod_info }

  let construct_workload workload_id pod_info : t = { workload_id; pod_info }

  let cons_pod_info ?network_keypair ?(has_archive_container = false)
      primary_container_id : Node.pod_info =
    { network_keypair; has_archive_container; primary_container_id }

  let get_nodes_from_workload t ~config =
    let%bind cwd = Unix.getcwd () in
    let open Malleable_error.Let_syntax in
    let%bind app_id =
      Deferred.bind ~f:Malleable_error.or_hard_error
        (Integration_test_lib.Util.run_cmd_or_error cwd "kubectl"
           ( base_kube_args config
           @ [ "get"
             ; "deployment"
             ; t.workload_id
             ; "-o"
             ; "jsonpath={.spec.selector.matchLabels.app}"
             ] ) )
    in
    let%map pod_ids_str =
      Integration_test_lib.Util.run_cmd_or_hard_error cwd "kubectl"
        ( base_kube_args config
        @ [ "get"; "pod"; "-l"; "app=" ^ app_id; "-o"; "name" ] )
    in
    let pod_ids =
      String.split pod_ids_str ~on:'\n'
      |> List.filter ~f:(Fn.compose not String.is_empty)
      |> List.map ~f:(String.substr_replace_first ~pattern:"pod/" ~with_:"")
    in
    (* we have a strict 1 workload to 1 pod setup, except the snark workers. *)
    (* elsewhere in the code I'm simply using List.hd_exn which is not ideal but enabled by the fact that in all relevant cases, there's only going to be 1 pod id in pod_ids *)
    (* TODO fix this^ and have a more elegant solution *)
    let pod_info = t.pod_info in
    { Node.app_id; pod_ids; pod_info; config }
end

type t =
  { namespace : string
  ; constants : Test_config.constants
  ; seeds : Node.t Core.String.Map.t
  ; block_producers : Node.t Core.String.Map.t
  ; snark_coordinators : Node.t Core.String.Map.t
  ; snark_workers : Node.t Core.String.Map.t
  ; archive_nodes : Node.t Core.String.Map.t
        (* ; nodes_by_pod_id : Node.t Core.String.Map.t *)
  ; testnet_log_filter : string
  ; genesis_keypairs : Network_keypair.t Core.String.Map.t
  }

let constants { constants; _ } = constants

let constraint_constants { constants; _ } = constants.constraints

let genesis_constants { constants; _ } = constants.genesis

let seeds { seeds; _ } = seeds

let block_producers { block_producers; _ } = block_producers

let snark_coordinators { snark_coordinators; _ } = snark_coordinators

let snark_workers { snark_workers; _ } = snark_workers

let archive_nodes { archive_nodes; _ } = archive_nodes

(* all_nodes returns all *actual* mina nodes; note that a snark_worker is a pod within the network but not technically a mina node, therefore not included here.  snark coordinators on the other hand ARE mina nodes *)
let all_nodes { seeds; block_producers; snark_coordinators; archive_nodes; _ } =
  List.concat
    [ Core.String.Map.to_alist seeds
    ; Core.String.Map.to_alist block_producers
    ; Core.String.Map.to_alist snark_coordinators
    ; Core.String.Map.to_alist archive_nodes
    ]
  |> Core.String.Map.of_alist_exn

(* all_pods returns everything in the network.  remember that snark_workers will never initialize and will never sync, and aren't supposed to *)
(* TODO snark workers and snark coordinators have the same key name, but different workload ids*)
let all_pods t =
  List.concat
    [ Core.String.Map.to_alist t.seeds
    ; Core.String.Map.to_alist t.block_producers
    ; Core.String.Map.to_alist t.snark_coordinators
    ; Core.String.Map.to_alist t.snark_workers
    ; Core.String.Map.to_alist t.archive_nodes
    ]
  |> Core.String.Map.of_alist_exn

(* all_non_seed_pods returns everything in the network except seed nodes *)
let all_non_seed_pods t =
  List.concat
    [ Core.String.Map.to_alist t.block_producers
    ; Core.String.Map.to_alist t.snark_coordinators
    ; Core.String.Map.to_alist t.snark_workers
    ; Core.String.Map.to_alist t.archive_nodes
    ]
  |> Core.String.Map.of_alist_exn

let genesis_keypairs { genesis_keypairs; _ } = genesis_keypairs

let lookup_node_by_pod_id t id =
  let pods = all_pods t |> Core.Map.to_alist in
  List.fold pods ~init:None ~f:(fun acc (node_name, node) ->
      match acc with
      | Some acc ->
          Some acc
      | None ->
          if String.equal id (List.hd_exn node.pod_ids) then
            Some (node_name, node)
          else None )

let all_pod_ids t =
  let pods = all_pods t |> Core.Map.to_alist in
  List.fold pods ~init:[] ~f:(fun acc (_, node) ->
      List.cons (List.hd_exn node.pod_ids) acc )

let initialize_infra ~logger network =
  let open Malleable_error.Let_syntax in
  let poll_interval = Time.Span.of_sec 15.0 in
  let max_polls = 40 (* 10 mins *) in
  let all_pods_set = all_pod_ids network |> String.Set.of_list in
  let kube_get_pods () =
    Integration_test_lib.Util.run_cmd_or_error_timeout ~timeout_seconds:60 "/"
      "kubectl"
      [ "-n"
      ; network.namespace
      ; "get"
      ; "pods"
      ; "-ojsonpath={range \
         .items[*]}{.metadata.name}{':'}{.status.phase}{'\\n'}{end}"
      ]
  in
  let parse_pod_statuses result_str =
    result_str |> String.split_lines
    |> List.map ~f:(fun line ->
           let parts = String.split line ~on:':' in
           assert (Mina_stdlib.List.Length.Compare.(parts = 2)) ;
           (List.nth_exn parts 0, List.nth_exn parts 1) )
    |> List.filter ~f:(fun (pod_name, _) ->
           String.Set.mem all_pods_set pod_name )
    (* this filters out the archive bootstrap pods, since they aren't in all_pods_set.  in fact the bootstrap pods aren't tracked at all in the framework *)
    |> String.Map.of_alist_exn
  in
  let rec poll n =
    [%log debug] "Checking kubernetes pod statuses, n=%d" n ;
    let is_successful_pod_status status = String.equal "Running" status in
    match%bind Deferred.bind ~f:Malleable_error.return (kube_get_pods ()) with
    | Ok str ->
        let pod_statuses = parse_pod_statuses str in
        [%log debug] "pod_statuses: \n %s"
          ( String.Map.to_alist pod_statuses
          |> List.map ~f:(fun (key, data) -> key ^ ": " ^ data ^ "\n")
          |> String.concat ) ;
        [%log debug] "all_pods: \n %s"
          (String.Set.elements all_pods_set |> String.concat ~sep:", ") ;
        let all_pods_are_present =
          List.for_all (String.Set.elements all_pods_set) ~f:(fun pod_id ->
              String.Map.mem pod_statuses pod_id )
        in
        let any_pods_are_not_running =
          (* there could be duplicate keys... *)
          List.exists
            (String.Map.data pod_statuses)
            ~f:(Fn.compose not is_successful_pod_status)
        in
        if not all_pods_are_present then (
          let present_pods = String.Map.keys pod_statuses in
          [%log fatal]
            "Not all pods were found when querying namespace; this indicates a \
             deployment error. Refusing to continue. \n\
             Expected pods: [%s].  \n\
             Present pods: [%s]"
            (String.Set.elements all_pods_set |> String.concat ~sep:"; ")
            (present_pods |> String.concat ~sep:"; ") ;
          Malleable_error.hard_error_string ~exit_code:5
            "Some pods were not found in namespace." )
        else if any_pods_are_not_running then
          let failed_pod_statuses =
            List.filter (String.Map.to_alist pod_statuses)
              ~f:(fun (_, status) -> not (is_successful_pod_status status))
          in
          if n > 0 then (
            [%log debug] "Got bad pod statuses, polling again ($failed_statuses"
              ~metadata:
                [ ( "failed_statuses"
                  , `Assoc
                      (List.Assoc.map failed_pod_statuses ~f:(fun v ->
                           `String v ) ) )
                ] ;
            let%bind () =
              after poll_interval |> Deferred.bind ~f:Malleable_error.return
            in
            poll (n - 1) )
          else (
            [%log fatal]
              "Got bad pod statuses, not all pods were assigned to nodes and \
               ready in time.  pod statuses: ($failed_statuses"
              ~metadata:
                [ ( "failed_statuses"
                  , `Assoc
                      (List.Assoc.map failed_pod_statuses ~f:(fun v ->
                           `String v ) ) )
                ] ;
            Malleable_error.hard_error_string ~exit_code:4
              "Some pods either were not assigned to nodes or did not deploy \
               properly." )
        else return ()
    | Error _ ->
        [%log debug] "`kubectl get pods` timed out, polling again" ;
        let%bind () =
          after poll_interval |> Deferred.bind ~f:Malleable_error.return
        in
        poll n
  in
  [%log info] "Waiting for pods to be assigned nodes and become ready" ;
  let res = poll max_polls in
  match%bind.Deferred res with
  | Error _ ->
      [%log error] "Not all pods were assigned nodes, cannot proceed!" ;
      res
  | Ok _ ->
      [%log info] "Pods assigned to nodes" ;
      res

%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Quorum Service==
%%% Using this service can provide Byzantine fault tolerance for any other
%%% services.  The service prefix is used to accept any service requests
%%% that match the prefix, while the suffix is used to achieve the
%%% configured number of service request responses
%%% (i.e., quorum: the minimum number of services able to process a
%%%  service request to achieve the same response).  If quorum is met,
%%% the agreed upon response is returned.  Otherwise, the service request to
%%% this service will timeout (i.e., receive no response).
%%% @end
%%%
%%% BSD LICENSE
%%% 
%%% Copyright (c) 2013-2014, Michael Truog <mjtruog at gmail dot com>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in
%%%       the documentation and/or other materials provided with the
%%%       distribution.
%%%     * All advertising materials mentioning features or use of this
%%%       software must display the following acknowledgment:
%%%         This product includes software developed by Michael Truog
%%%     * The name of the author may not be used to endorse or promote
%%%       products derived from this software without specific prior
%%%       written permission
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%% CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
%%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
%%% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
%%% DAMAGE.
%%%
%%% @author Michael Truog <mjtruog [at] gmail (dot) com>
%%% @copyright 2013-2014 Michael Truog
%%% @version 1.4.0 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_service_quorum).
-author('mjtruog [at] gmail (dot) com').

-behaviour(cloudi_service).

%% external interface

%% cloudi_service callbacks
-export([cloudi_service_init/4,
         cloudi_service_handle_request/11,
         cloudi_service_handle_info/3,
         cloudi_service_terminate/3]).

-include_lib("cloudi_core/include/cloudi_logger.hrl").
-include_lib("cloudi_core/include/cloudi_service.hrl").

% quorum is specified either as an absolute integer or percentage,
% or as 'byzantine' for (N - floor((N - 1) / 3))
% ('byzantine' requires that less than 1/3rd of the responses be erroneous
%  (e.g., a timeout or a non-matching response))
-define(DEFAULT_QUORUM,                 byzantine).
-define(DEFAULT_USE_RESPONSE_INFO,           true). % check for match

-record(request,
    {
        type :: cloudi_service:request_type(),
        name :: cloudi_service:service_name(),
        pattern :: cloudi_service:service_name_pattern(),
        timeout :: cloudi_service:timeout_milliseconds(),
        pid :: pid(),
        count_required :: pos_integer(),
        count_total :: pos_integer(),
        count_responses = 0 :: non_neg_integer(),
        responses = [] :: list({{cloudi_service:response_info(),
                                 cloudi_service:response()},
                                pos_integer()}) % response -> count
    }).

-record(state,
    {
        prefix :: string(),
        quorum :: byzantine | number(),
        use_response_info :: boolean(),
        requests = dict:new() :: dict(), % Original TransId -> #request{}
        pending = dict:new() :: dict() % TransId -> Original TransId
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_service
%%%------------------------------------------------------------------------

cloudi_service_init(Args, Prefix, _Timeout, Dispatcher) ->
    Defaults = [
        {quorum,                   ?DEFAULT_QUORUM},
        {use_response_info,        ?DEFAULT_USE_RESPONSE_INFO}],
    [Quorum, UseResponseInfo] = cloudi_proplists:take_values(Defaults, Args),
    true = ((is_atom(Quorum) andalso
             (Quorum =:= byzantine)) orelse
            (is_float(Quorum) andalso
             (Quorum > 0.0) andalso (Quorum =< 1.0)) orelse
            (is_integer(Quorum) andalso
             (Quorum > 0))),
    true = is_boolean(UseResponseInfo),
    false = trie:is_pattern(Prefix),
    cloudi_service:subscribe(Dispatcher, "*"),
    {ok, #state{quorum = Quorum,
                use_response_info = UseResponseInfo}}.

cloudi_service_handle_request(Type, Name, Pattern, RequestInfo, Request,
                              Timeout, Priority, TransId, Pid,
                              #state{quorum = Quorum,
                                     requests = Requests,
                                     pending = Pending} = State,
                              Dispatcher) ->
    [QuorumName] = cloudi_service:service_name_parse(Name, Pattern),
    case cloudi_service:mcast_async_active(Dispatcher, QuorumName,
                                           RequestInfo, Request,
                                           Timeout, Priority) of
        {ok, QuorumTransIds} ->
            {Count, NewPending} = pending_store(QuorumTransIds,
                                                Pending, TransId),
            CountRequired = if
                Quorum =:= byzantine ->
                    if
                        Count < 4 ->
                            ?LOG_ERROR("Byzantine quorum not met! ~p N=~p",
                                       [QuorumName, Count]),
                            undefined;
                        true ->
                            Count - cloudi_math:floor((Count - 1) / 3)
                    end;
                is_integer(Quorum) ->
                    if
                        Quorum > Count ->
                            ?LOG_ERROR("Absolute quorum not met! ~p N=~p",
                                       [QuorumName, Count]),
                            undefined;
                        true ->
                            Quorum
                    end;
                is_float(Quorum) ->
                    erlang:min(Count,
                               cloudi_math:ceil(Quorum * Count))
            end,
            NewRequests = if
                CountRequired =:= undefined ->
                    Requests;
                true ->
                    dict:store(TransId,
                               #request{type = Type,
                                        name = Name,
                                        pattern = Pattern,
                                        timeout = Timeout,
                                        pid = Pid,
                                        count_required = CountRequired,
                                        count_total = Count},
                               Requests)
            end,
            {noreply, State#state{requests = NewRequests,
                                  pending = NewPending}};
        {error, timeout} ->
            {reply, <<>>, State}
    end.

cloudi_service_handle_info(#return_async_active{response_info = ResponseInfo,
                                                response = Response,
                                                trans_id = QuorumTransId},
                           #state{use_response_info = UseResponseInfo,
                                  requests = Requests,
                                  pending = Pending} = State,
                           Dispatcher) ->
    TransId = dict:fetch(QuorumTransId, Pending),
    {noreply, State#state{requests = request_check(ResponseInfo, Response,
                                                   TransId, Requests,
                                                   UseResponseInfo, Dispatcher),
                          pending = dict:erase(QuorumTransId, Pending)}};

cloudi_service_handle_info(#timeout_async_active{trans_id = QuorumTransId},
                           #state{requests = Requests,
                                  pending = Pending} = State,
                           Dispatcher) ->
    TransId = dict:fetch(QuorumTransId, Pending),
    {noreply, State#state{requests = request_timeout(TransId, Requests,
                                                     Dispatcher),
                          pending = dict:erase(QuorumTransId, Pending)}};

cloudi_service_handle_info(Request, State, _Dispatcher) ->
    ?LOG_WARN("Unknown info \"~p\"", [Request]),
    {noreply, State}.

cloudi_service_terminate(_Reason, _Timeout, #state{}) ->
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

pending_store(QuorumTransIds, Pending, TransId) ->
    pending_store(QuorumTransIds, 0, Pending, TransId).

pending_store([], Count, Pending, _TransId)
    when Count > 0 ->
    {Count, Pending};
pending_store([QuorumTransId | L], Count, Pending, TransId) ->
    pending_store(L, Count + 1,
                  dict:store(QuorumTransId, TransId, Pending), TransId).

request_check(ResponseInfo, Response, TransId, Requests,
              UseResponseInfo, Dispatcher) ->
    case dict:find(TransId, Requests) of
        {ok, #request{% return data
                      type = ResponseType,
                      name = ResponseName,
                      pattern = ResponsePattern,
                      timeout = ResponseTimeout,
                      pid = ResponsePid,
                      % quorum data
                      count_required = CountRequired,
                      count_total = CountTotal,
                      count_responses = CountResponses,
                      responses = Responses} = Request} ->
            Key = if
                UseResponseInfo =:= true ->
                    {ResponseInfo, Response};
                UseResponseInfo =:= false ->
                    Response
            end,
            Count = case orddict:find(Key, Responses) of
                {ok, I} ->
                    % do not check to see if it is impossible to meet the
                    % CountRequired, given the CountTotal, since that should
                    % not be the typical case and only causes the current
                    % memory consumption to last a little bit longer
                    % (i.e., until all responses or timeouts are received)
                    I + 1;
                error ->
                    1
            end,
            NewCountResponses = CountResponses + 1,
            if
                Count == CountRequired ->
                    cloudi_service:return_nothrow(Dispatcher, ResponseType,
                                                  ResponseName,
                                                  ResponsePattern,
                                                  ResponseInfo, Response,
                                                  ResponseTimeout,
                                                  TransId,
                                                  ResponsePid),
                    dict:erase(TransId, Requests);
                NewCountResponses == CountTotal ->
                    cloudi_service:return_nothrow(Dispatcher, ResponseType,
                                                  ResponseName,
                                                  ResponsePattern,
                                                  <<>>, <<>>,
                                                  ResponseTimeout,
                                                  TransId,
                                                  ResponsePid),
                    dict:erase(TransId, Requests);
                true ->
                    NewResponses = orddict:store(Key, Count, Responses),
                    NewRequest = Request#request{
                                     count_responses = NewCountResponses,
                                     responses = NewResponses},
                    dict:store(TransId, NewRequest, Requests)
            end;
        error ->
            % already met quorum and was returned
            Requests
    end.

request_timeout(TransId, Requests, Dispatcher) ->
    case dict:find(TransId, Requests) of
        {ok, #request{% return data
                      type = ResponseType,
                      name = ResponseName,
                      pattern = ResponsePattern,
                      timeout = ResponseTimeout,
                      pid = ResponsePid,
                      % quorum data
                      count_total = CountTotal,
                      count_responses = CountResponses} = Request} ->
            NewCountResponses = CountResponses + 1,
            if
                NewCountResponses == CountTotal ->
                    cloudi_service:return_nothrow(Dispatcher, ResponseType,
                                                  ResponseName,
                                                  ResponsePattern,
                                                  <<>>, <<>>,
                                                  ResponseTimeout,
                                                  TransId,
                                                  ResponsePid),
                    dict:erase(TransId, Requests);
                true ->
                    NewRequest = Request#request{
                                     count_responses = NewCountResponses},
                    dict:store(TransId, NewRequest, Requests)
            end;
        error ->
            % already met quorum and was returned
            Requests
    end.


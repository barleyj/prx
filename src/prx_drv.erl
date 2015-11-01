%%% Copyright (c) 2015, Michael Santos <michael.santos@gmail.com>
%%% Permission to use, copy, modify, and/or distribute this software for any
%%% purpose with or without fee is hereby granted, provided that the above
%%% copyright notice and this permission notice appear in all copies.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
-module(prx_drv).
-behaviour(gen_server).

-export([
        call/4,
        stdin/3,

        start_link/0,
        stop/1,

        progname/0
    ]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


-record(state, {
        drv,
        pstree = dict:new()
    }).

call(Drv, Chain, Call, Argv) when Call == fork; Call == clone ->
    gen_server:call(Drv, {Chain, Call, Argv}, infinity);
call(Drv, Chain, Call, Argv) ->
    Reply = gen_server:call(Drv, {Chain, Call, Argv}, infinity),
    case Reply of
        true ->
            call_reply(Drv, Chain, Call, infinity);
        Error ->
            Error
    end.

stdin(Drv, Chain, Buf) ->
    gen_server:call(Drv, {Chain, stdin, Buf}, infinity).

stop(Drv) ->
    catch gen_server:stop(Drv),
    ok.

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    Options = application:get_env(prx, options, []) ++
        [{progname, progname()}, {ctldir, basedir(?MODULE)}],
    case alcove_drv:start_link(Options) of
        {ok, Drv} ->
            {ok, #state{drv = Drv}};
        Error ->
            {stop, Error}
    end.

handle_call(init, {Pid, _Tag}, #state{pstree = PS} = State) ->
    {reply, ok, State#state{pstree = dict:store([], Pid, PS)}};

handle_call(raw, {_Pid, _Tag}, #state{drv = Drv} = State) ->
    Reply = alcove_drv:raw(Drv),
    {reply, Reply, State};

handle_call({Chain, fork, _}, {Pid, _Tag}, #state{
        drv = Drv,
        pstree = PS
    } = State) ->
    try alcove:fork(Drv, Chain, infinity) of
        {ok, Child} ->
            erlang:monitor(process, Pid),
            Chain1 = Chain ++ [Child],
            {reply, {ok, Chain1}, State#state{pstree = dict:store(Chain1, Pid, PS)}};
        {error, _} = Error ->
            {reply, Error, State}
    catch
        _Error:_Reason ->
            exit(Pid, kill),
            {noreply, State}
    end;
handle_call({Chain, clone, Flags}, {Pid, _Tag}, #state{
        drv = Drv,
        pstree = PS
    } = State) ->
    try alcove:clone(Drv, Chain, Flags, infinity) of
        {ok, Child} ->
            erlang:monitor(process, Pid),
            Chain1 = Chain ++ [Child],
            {reply, {ok, Chain1}, State#state{pstree = dict:store(Chain1, Pid, PS)}};
        Error ->
            {reply, Error, State}
    catch
        _Error:_Reason ->
            exit(Pid, kill),
            {noreply, State}
    end;

handle_call({Chain, stdin, Buf}, {Pid, _Tag}, #state{
        drv = Drv
    } = State) ->
    try alcove:stdin(Drv, Chain, Buf) of
        Reply ->
            {reply, Reply, State}
    catch
        _Error:_Reason ->
            exit(Pid, kill),
            {noreply, State}
    end;
handle_call({Chain, Call, Argv}, {_Pid, _Tag}, #state{
        drv = Drv
    } = State) ->
    Data = alcove_codec:call(Call, Chain, Argv),
    Reply = gen_server:call(Drv, {send, Data}, infinity),
    {reply, Reply, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({Event, Drv, Chain, Buf}, #state{
        drv = Drv,
        pstree = PS
    } = State) ->
    case dict:find(Chain, PS) of
        error ->
            ok;
        {ok, Pid} ->
            Pid ! {Event, self(), Chain, Buf}
    end,
    {noreply, State};

handle_info({'DOWN', _MonitorRef, process, Pid, _Info}, #state{pstree = PS} = State) ->
    case dict:fold(fun(K,V,_) when V =:= Pid -> K; (_,_,A) -> A end, undefined, PS) of
        undefined ->
            {noreply, State};
        Chain ->
            PS1 = dict:filter(fun(Child, Task) ->
                        case lists:prefix(Chain, Child) of
                            true ->
                                erlang:exit(Task, kill),
                                false;
                            false ->
                                true
                        end
                end,
                PS),
            {noreply, State#state{pstree = PS1}}
    end;

handle_info({'EXIT', Drv, Reason}, #state{drv = Drv} = State) ->
    {stop, {shutdown, Reason}, State};

handle_info(Event, State) ->
    error_logger:info_report([{unhandled, Event}]),
    {noreply, State}.

terminate(_Reason, #state{drv = Drv}) ->
    catch alcove_drv:stop(Drv),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

call_reply(Drv, Chain, exit, Timeout) ->
    receive
        {alcove_ctl, Drv, Chain, fdctl_closed} ->
            ok;
        {alcove_ctl, Drv, _Chain, badpid} ->
            erlang:error(badpid)
    after
        Timeout ->
            erlang:error(timeout)
    end;
call_reply(Drv, Chain, Call, Timeout) when Call =:= execve; Call =:= execvp ->
    receive
        {alcove_ctl, Drv, Chain, fdctl_closed} ->
            ok;
        {alcove_ctl, Drv, _Chain, badpid} ->
            erlang:error(badpid);
        {alcove_call, Drv, Chain, Event} ->
            Event
    after
        Timeout ->
            erlang:error(timeout)
    end;
call_reply(Drv, Chain, Call, Timeout) ->
    receive
        {alcove_ctl, Drv, Chain, fdctl_closed} ->
            call_reply(Drv, Chain, Call, Timeout);
        {alcove_event, Drv, Chain, {termsig,_} = Event} ->
            erlang:error(Event);
        {alcove_event, Drv, Chain, {exit_status,_} = Event} ->
            erlang:error(Event);
        {alcove_ctl, Drv, _Chain, badpid} ->
            erlang:error(badpid);
        {alcove_call, Drv, Chain, Event} ->
            Event
    after
        Timeout ->
            erlang:error(timeout)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
basedir(Module) ->
    case code:priv_dir(Module) of
        {error, bad_name} ->
            filename:join([
                filename:dirname(code:which(Module)),
                "..",
                "priv"
            ]);
        Dir ->
            Dir
        end.

progname() ->
    filename:join([basedir(prx), "prx"]).

-module(app_reloader).
-author("Victor Kotseruba <barbuzaster@gmail.com>").
-behaviour(gen_server).

-define(CHECK_INTERVAL, 1000).

-include_lib("kernel/include/file.hrl").


-type appname() :: atom().

-type modname() :: atom().

-type mode() :: source | binary.

-type mtime() :: {{non_neg_integer(), non_neg_integer(), non_neg_integer()},
                  {non_neg_integer(), non_neg_integer(), non_neg_integer()}}.

-record(state, {app :: appname(),
                modules :: [modname()],
                mode :: mode(),
                dep_graph :: digraph()}).

-record(module, {module :: modname(),
                 mtime :: mtime() | 'undefined'}).


%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export_type([appname/0, mode/0]).

-export([start_link/2, start/2]).


%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec start_link(appname(), mode()) -> {error, any()} | {ok, pid()}.
start_link(App, Mode) ->
  gen_server:start_link({local, server_name(App)}, ?MODULE, {App, Mode}, []).


-spec start(appname(), mode()) -> {error, any()} | {ok, pid()}.
start(App, Mode) ->
  gen_server:start({local, server_name(App)}, ?MODULE, {App, Mode}, []).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init({appname(), mode()}) -> {ok, #state{}}.
init({App, Mode}) ->
  error_logger:info_msg("starting reloader for ~p in ~p mode", [App, Mode]),
  DepGraph = digraph:new([acyclic, private]),
  digraph_dep(DepGraph, App),
  State = #state{app=App,
                 modules=app_modules(App, Mode),
                 mode=Mode,
                 dep_graph=DepGraph},
  timer:send_after(?CHECK_INTERVAL, check),
  {ok, State}.


-spec handle_call(any(), any(), #state{}) -> {reply, ok, #state{}}.
handle_call(_Request, _From, State) ->
  {reply, ok, State}.


-spec handle_cast(any(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
  {noreply, State}.


-spec handle_info(check, #state{}) -> {noreply, #state{}}.
handle_info(check, State=#state{app=App, mode=Mode, modules=OldModules, dep_graph=DepGraph}) ->
  case app_modules(App, Mode) of
    OldModules ->
      timer:send_after(?CHECK_INTERVAL, check),
      {noreply, State};
    Modules ->
      AllModsFound = lists:all(fun(#module{mtime=Mtime}) ->
                                 Mtime =/= undefined
                               end, Modules),
      if
        AllModsFound ->
          NewModules = Modules -- OldModules,
          ModulesPrepared = prepare_modules(NewModules, Mode),
          if
            ModulesPrepared -> reload_app(DepGraph, NewModules);
            true -> error_logger:error_msg("compilation failed")
          end,
          timer:send_after(?CHECK_INTERVAL, check),
          {noreply, State#state{modules=Modules}};
        true ->
          timer:send_after(erlang:trunc(?CHECK_INTERVAL / 5) + 1, check),
          {noreply, State}
      end
  end.


-spec terminate(any(), #state{}) -> ok.
terminate(_Reason, _State) ->
  ok.


-spec code_change(any(), #state{}, any()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec reload_app(digraph(), [#module{}]) -> no_return().
reload_app(DepGraph, Modules) ->
  StartOrder = digraph_utils:topsort(DepGraph), 
  lists:foreach(fun application:stop/1, lists:reverse(StartOrder)),
  lists:foreach(fun(Module) -> reload_module(Module) end, Modules),
  lists:foreach(fun application:start/1, StartOrder).


-spec prepare_modules([#module{} | modname()], mode()) -> boolean().
prepare_modules(Modules, source) ->
  lists:all(fun(Module) -> compile_module(Module) end, Modules);

prepare_modules(_Modules, binary) ->
  true.


-spec reload_module(#module{} | modname()) -> {module, modname()}.
reload_module(#module{module=Module}) ->
  reload_module(Module);

reload_module(Module) when is_atom(Module) ->
  error_logger:info_msg("reload ~p", [Module]),
  code:purge(Module),
  code:load_file(Module).


-spec compile_module(#module{} | modname()) -> boolean().
compile_module(#module{module=Module}) ->
  compile_module(Module);

compile_module(Module) when is_atom(Module) ->
  CompileInfo = Module:module_info(compile),
  Source = proplists:get_value(source, CompileInfo),
  RootDir = filename:dirname(filename:dirname(Source)),
  CompileOptions = [{outdir, filename:join(RootDir, "ebin")}] ++
                   lists:usort([verbose, report_errors, report_warnings, debug_info]
                               ++ find_compile_options(Source)) ++
                   [{i, filename:absname("deps")},
                    {i, filename:absname("apps")},
                    {i, filename:join(RootDir, "include")}],
  error_logger:info_msg("compile ~p", [Module]),
  Result = compile:file(Source, CompileOptions),
  case Result of
    error -> false;
    {error, _, _} -> false;
    _ -> true
  end.

-spec binary_mtime(modname()) -> mtime() | undefined.
binary_mtime(Module) ->
  case file:read_file_info(code:which(Module)) of
    {error, enoent} -> undefined;
    {ok, #file_info{mtime=Mtime}} -> Mtime
  end.

-spec source_mtime(modname()) -> mtime().
source_mtime(Module) ->
  CompileInfo = Module:module_info(compile),
  Path = proplists:get_value(source, CompileInfo),
  case file:read_file_info(Path) of
    {error, enoent} -> exit(source_not_found); 
    {ok, #file_info{mtime=Mtime}} -> Mtime
  end.

-spec module_by_name(modname(), mode()) -> #module{}.
module_by_name(Module, binary) ->
  #module{module=Module, mtime=binary_mtime(Module)};

module_by_name(Module, source) ->
  #module{module=Module, mtime=source_mtime(Module)}.


-spec app_modules(appname(), mode()) -> [#module{}].
app_modules(App, Mode) ->
  {ok, ModNames} = application:get_key(App, modules),
  [module_by_name(Module, Mode) || Module <- ModNames].


-spec digraph_dep(digraph(), appname()) -> no_return().
digraph_dep(Graph, AppName) ->
  AllApps = lists:map(fun({App, _, _}) -> App end, application:which_applications()),
  DependentApps = lists:filter(fun(App) ->
                                 {ok, DependsOn} = application:get_key(App, applications),
                                 lists:member(AppName, DependsOn)
                               end, AllApps),
  digraph:add_vertex(Graph, AppName),
  lists:foreach(fun(DependentApp) ->
                  digraph_dep(Graph, DependentApp),
                  digraph:add_edge(Graph, AppName, DependentApp)
                end, DependentApps).


-spec find_compile_options(string()) -> list().
find_compile_options(Path) ->
  lists:foldl(fun(Item, Options) ->
                case Item of
                  {attribute, _, compile, Data} -> Options ++ Data;
                  _ -> Options
                end
               end, [], edoc:read_source(Path)).


-spec server_name(appname()) -> atom().
server_name(App) ->
  list_to_atom(lists:flatten([atom_to_list(?MODULE), "__", atom_to_list(App)])).

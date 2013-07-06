# app_reloader

compile and reload erlang app (and dependent apps) when source code or binary changes

## usage

add app reloader as rebar dep

    {app_reloader, "0.0.1", {git, "https://github.com/barbuza/app_reloader.git"}}

compile and reload app when source changes

    app_reloader:start_link(appname, source).

reload app when binary changes (assume we have some external auto build system)

    app_reloader:start_link(appname, binary).

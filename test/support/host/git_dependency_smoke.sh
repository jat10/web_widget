#!/usr/bin/env bash
set -euo pipefail

project_root=$(pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
source_repo="$scratch/source"
host="$scratch/host"
mkdir -p "$source_repo" "$host"

# Make a committed snapshot, including the current change, without touching this checkout.
while IFS= read -r -d '' file; do
  if [ -f "$file" ]; then
    mkdir -p "$source_repo/$(dirname "$file")"
    cp "$file" "$source_repo/$file"
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

git -C "$source_repo" init -q
git -C "$source_repo" -c user.name='Widget CI' -c user.email='widget@example.invalid' add .
git -C "$source_repo" -c user.name='Widget CI' -c user.email='widget@example.invalid' commit -qm 'test: snapshot widget dependency'
git -C "$source_repo" tag asset-smoke

cat > "$host/mix.exs" <<'EOF'
defmodule WidgetAssetSmoke.MixProject do
  use Mix.Project

  def project do
    [app: :widget_asset_smoke, version: "0.0.1", deps: deps()]
  end

  defp deps do
    [{:web_widget, git: System.fetch_env!("WEB_WIDGET_GIT_URL"), tag: "asset-smoke"}]
  end
end
EOF

cd "$host"
export WEB_WIDGET_GIT_URL="file://$source_repo"
MIX_ENV=prod mix deps.get

for file in embed.js app.js app.css web-widget.js web-widget.css widget-client.js; do
  test -s "deps/web_widget/priv/static/assets/$file"
  cmp "$project_root/priv/static/assets/$file" "deps/web_widget/priv/static/assets/$file"
  git -C deps/web_widget ls-files --error-unmatch "priv/static/assets/$file" >/dev/null
done

cat > smoke.exs <<'EOF'
defmodule WidgetAssetSmoke.Router do
  use Phoenix.Router
  import WebWidget.Router

  web_widget("/widget")
end

for {file, type} <- [{"embed.js", "text/javascript"}, {"app.css", "text/css"}] do
  conn =
    Plug.Test.conn(:get, "/web_widget/assets/#{file}")
    |> WidgetAssetSmoke.Router.call(WidgetAssetSmoke.Router.init([]))

  unless conn.status == 200 and byte_size(conn.resp_body) > 100 and
           Plug.Conn.get_resp_header(conn, "content-type") == [type] do
    raise "fresh Git dependency did not serve #{file}"
  end
end
EOF

MIX_ENV=prod mix run --no-start smoke.exs
echo 'Fresh tagged Git dependency serves its complete compiled bundle.'

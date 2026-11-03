#!/usr/bin/env bash
# cce-guardian / ledger.sh
#
# 「どのClaudeアカウントから、どのブラウザ（deviceId）が見えるか」の台帳を作る。
# Claudeアカウントを切り替えるたびに実行すると、アカウント × deviceId × マシン/プロファイル の表が育つ。
#
#   ./ledger.sh          # 今のClaudeアカウントで接続ブラウザを調べ、台帳に追記（初見のdeviceIdはラベルを聞く）
#   ./ledger.sh show     # 台帳を表示
#   ./ledger.sh label <deviceId> "<ラベル>"   # ラベルを付け直す
#
# 台帳の場所: ~/.cce-guardian/devices.json （リポジトリには入れない）
# ブラウザには触れない。一覧の取得だけを許可して Claude Code を起動する。

set -euo pipefail

DIR="${CEG_HOME:-$HOME/.cce-guardian}"
LEDGER="$DIR/devices.json"
mkdir -p "$DIR"
[[ -f "$LEDGER" ]] || echo '{"devices":{}}' > "$LEDGER"

need_node() { command -v node >/dev/null || { echo "node が必要です（Claude Code と一緒に入っているはずです）" >&2; exit 1; }; }
need_node

# いまの Claude Code のアカウント（~/.claude.json の oauthAccount）
current_account() {
  # 自動で取れない場合は CEG_ACCOUNT=aki@aicu.ai ./ledger.sh のように指定できる
  if [[ -n "${CEG_ACCOUNT:-}" ]]; then printf '%s\t\t\n' "$CEG_ACCOUNT"; return; fi
  node -e '
    const fs=require("fs"),p=require("path").join(require("os").homedir(),".claude.json");
    let a={};try{a=JSON.parse(fs.readFileSync(p,"utf8")).oauthAccount||{}}catch(e){}
    console.log([a.emailAddress||"unknown",a.organizationUuid||"",a.organizationName||""].join("\t"));'
}

show() {
  LEDGER="$LEDGER" node -e '
    const l=JSON.parse(require("fs").readFileSync(process.env.LEDGER,"utf8"));
    const rows=[];
    for (const [id,d] of Object.entries(l.devices)) for (const [acct,s] of Object.entries(d.seenBy||{}))
      rows.push({acct,id,os:d.os||"",label:d.label||"(未設定)",name:s.name||"",last:s.lastSeen||""});
    rows.sort((a,b)=>a.acct.localeCompare(b.acct)||a.label.localeCompare(b.label));
    if(!rows.length){console.log("台帳は空です。./ledger.sh を実行してください。");process.exit(0)}
    console.log("| Claudeアカウント | ラベル（マシン/プロファイル） | OS | deviceId | そのアカウントでの表示名 | 最終確認 |");
    console.log("| --- | --- | --- | --- | --- | --- |");
    for (const r of rows) console.log(`| ${r.acct} | ${r.label} | ${r.os} | ${r.id.slice(0,8)}… | ${r.name} | ${r.last} |`);
    // 同じdeviceIdが複数アカウントから見えていたら警告
    for (const [id,d] of Object.entries(l.devices)) { const n=Object.keys(d.seenBy||{}).length;
      if(n>1) console.log(`\n⚠ ${d.label||id.slice(0,8)} は ${n} つのClaudeアカウントから見えています。`); }'
}

label() {
  LEDGER="$LEDGER" ID="$1" LABEL="$2" node -e '
    const fs=require("fs"),l=JSON.parse(fs.readFileSync(process.env.LEDGER,"utf8"));
    const id=Object.keys(l.devices).find(k=>k.startsWith(process.env.ID));
    if(!id){console.error("その deviceId は台帳にありません");process.exit(1)}
    l.devices[id].label=process.env.LABEL; fs.writeFileSync(process.env.LEDGER,JSON.stringify(l,null,2));
    console.log("ラベルを更新しました: "+id.slice(0,8)+"… → "+process.env.LABEL);'
}

case "${1:-scan}" in
  show) show; exit 0 ;;
  label) [[ $# -ge 3 ]] || { echo "使い方: ./ledger.sh label <deviceId> \"<ラベル>\"" >&2; exit 1; }; label "$2" "$3"; exit 0 ;;
  scan) ;;
  *) echo "使い方: ./ledger.sh [scan|show|label <deviceId> <ラベル>]" >&2; exit 1 ;;
esac

IFS=$'\t' read -r ACCT ORG ORGNAME < <(current_account)
echo "[ledger] Claudeアカウント: $ACCT ${ORGNAME:+($ORGNAME)}" >&2

RAW="$(claude --chrome -p 'Call list_connected_browsers once. Then output ONLY a JSON array, no prose and no code fences, of objects with keys deviceId, name, osPlatform, inUse, copied exactly from the result. Do not call any other tool.' \
  --allowedTools 'mcp__claude-in-chrome__list_connected_browsers' \
  --disallowedTools 'mcp__claude-in-chrome__computer,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__javascript_tool,mcp__claude-in-chrome__form_input,Bash,Write,Edit')"

# 新しい deviceId を書き出し、ラベルを聞く
NEW_IDS="$(LEDGER="$LEDGER" RAW="$RAW" ACCT="$ACCT" ORG="$ORG" node -e '
  const fs=require("fs"),l=JSON.parse(fs.readFileSync(process.env.LEDGER,"utf8"));
  const m=process.env.RAW.match(/\[[\s\S]*\]/); if(!m){console.error("一覧を読み取れませんでした:\n"+process.env.RAW);process.exit(1)}
  const list=JSON.parse(m[0]), now=new Date().toISOString().slice(0,16).replace("T"," "), fresh=[];
  for (const b of list){ const d=l.devices[b.deviceId] ||= {os:b.osPlatform,label:"",seenBy:{}};
    if(!d.label) fresh.push(b.deviceId);
    const s=d.seenBy[process.env.ACCT] ||= {firstSeen:now,org:process.env.ORG};
    Object.assign(s,{name:b.name,lastSeen:now,inUse:!!b.inUse}); }
  fs.writeFileSync(process.env.LEDGER,JSON.stringify(l,null,2));
  console.error(`[ledger] ${list.length} 台のブラウザを記録しました`);
  console.log(fresh.map(id=>id+"\t"+(l.devices[id].os||"")).join("\n"));')"

if [[ -n "$NEW_IDS" && -t 0 ]]; then
  echo "" >&2
  echo "初めて見るブラウザがあります。どのマシンのどのプロファイルか、ラベルを付けてください（空でスキップ）。" >&2
  while IFS=$'\t' read -r ID OS; do
    [[ -z "$ID" ]] && continue
    read -r -p "  ${ID:0:8}… (${OS}) のラベル 例「Win自宅/Default」: " L </dev/tty || L=""
    [[ -n "$L" ]] && label "$ID" "$L" >/dev/null
  done <<< "$NEW_IDS"
fi

echo "" >&2
show

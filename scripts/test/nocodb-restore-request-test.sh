#!/usr/bin/env bash
# Bounded producer-contract tests for the restored NocoDB request consumer.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# shellcheck source=scripts/test/lib/nocodb-restore-command.sh
source scripts/test/lib/nocodb-restore-command.sh

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-restore-request-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

request_script="$(nocodb_restore_request_script)"

cat >"$fixture/mock-fetch.mjs" <<'EOF'
import {appendFileSync} from 'node:fs';

const canaryPath = 'download/issue334_acceptance/recovery-canary-v1/issue334-recovery-canary-v1_abcD1.txt';
const canarySha256 = '09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3';
const canaryBytes = new TextEncoder().encode('nocodb-issue334-attachment-canary-v1\n');
const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: {'Content-Type':'application/json'}
});
const readyDecision = () => ({
  kind:'nocodb-attachment-recovery-canary', version:1, state:'ready',
  baseId:'base-acceptance', sourceId:'source-operator', tableId:'table-decision', rowId:'41',
  savedView:{id:'view-facts',tableId:'table-facts',title:'acceptance_facts',type:3},
  commentId:'comment-canary',
  attachment:{id:'attachment-canary',path:canaryPath,title:'issue334-recovery-canary-v1.txt',
    mimetype:'text/plain',size:37,sha256:canarySha256}
});

globalThis.fetch = async (input, options = {}) => {
  const url = new URL(String(input));
  const method = options.method || 'GET';
  appendFileSync(process.env.NOCODB_RESTORE_REQUEST_EVENTS, `${method} ${url.pathname}${url.search}\n`);
  const fixtureCase = process.env.NOCODB_RESTORE_REQUEST_CASE || 'valid';

  if (url.pathname === '/api/v1/health' && method === 'GET') return json({message:'OK'});
  if (url.pathname === '/api/v1/auth/user/signin' && method === 'POST') return json({token:'fixture.jwt-token'});
  if (url.pathname === '/api/v2/meta/workspaces' && method === 'GET') return json({list:[{id:'workspace-1',title:'Automation Data'}]});
  if (url.pathname === '/api/v2/meta/bases' && method === 'GET') return json({list:[{id:'base-acceptance',title:'issue334_acceptance',fk_workspace_id:'workspace-1'}]});
  if (url.pathname === '/api/v2/meta/workspaces/workspace-1/integrations' && method === 'GET') return json({list:[
    {id:'integration-reader',title:'automation-data/issue334_acceptance/reader',type:'db',sub_type:'pg'},
    {id:'integration-operator',title:'automation-data/issue334_acceptance/operator',type:'db',sub_type:'pg'}
  ]});
  if (url.pathname === '/api/v2/meta/bases/base-acceptance/sources' && method === 'GET') return json({list:[{id:'source-reader'},{id:'source-operator'}]});
  if (url.pathname === '/api/v2/meta/bases/base-acceptance/sources/source-reader' && method === 'GET') return json({id:'source-reader',fk_integration_id:'integration-reader',alias:'Read Model',config:{searchPath:['read_model']},is_data_readonly:true,is_schema_readonly:true});
  if (url.pathname === '/api/v2/meta/bases/base-acceptance/sources/source-operator' && method === 'GET') return json({id:'source-operator',fk_integration_id:fixtureCase === 'wrong-integration' ? 'replacement' : 'integration-operator',alias:'Operator',config:{searchPath:['operator']},is_data_readonly:false,is_schema_readonly:true});
  if (url.pathname === '/api/v2/meta/bases/base-acceptance/tables' && method === 'GET') return json({list:[
    {id:'table-facts',title:'acceptance_facts',table_name:'acceptance_facts',schema:'read_model',source_id:'source-reader'},
    {id:'table-decision',title:'acceptance_decision',table_name:'acceptance_decision',schema:'operator',source_id:'source-operator'}
  ]});
  if (url.pathname === '/api/v2/meta/tables/table-facts/views' && method === 'GET') {
    const view = {id:'view-facts',fk_model_id:'table-facts',title:'acceptance_facts',type:3,uuid:null};
    if (fixtureCase === 'wrong-saved-view') view.fk_model_id = 'table-decision';
    if (fixtureCase === 'wrong-view-id') view.id = 'replacement-view';
    if (fixtureCase === 'wrong-view-title') view.title = 'Grid';
    if (fixtureCase === 'wrong-view-type') view.type = 1;
    return json({list:[view]});
  }
  if (url.pathname === '/api/v2/tables/table-facts/records' && method === 'GET') return json({list:[{id:1,fact:'fixture'}]});
  if (url.pathname === '/api/v2/tables/table-facts/records' && method === 'POST') return json({error:'source_read_only'}, 403);
  if (url.pathname === '/api/v2/tables/table-decision/records' && method === 'POST') return json({id:99});
  if (url.pathname === '/api/v2/tables/table-decision/records' && method === 'PATCH') return json({error:'ERR_DATABASE_OP_FAILED'}, 400);
  if (url.pathname === '/api/v2/tables/table-decision/records' && method === 'DELETE') return json([{id:99}]);
  if (url.pathname === '/api/v2/tables/table-decision/records' && method === 'GET') {
    const decision = readyDecision();
    if (fixtureCase === 'extra-canary-key') decision.attachment.unexpected = true;
    if (fixtureCase === 'external-canary-path') decision.attachment.path = 'https://example.invalid/canary.txt';
    if (fixtureCase === 'pending-canary') decision.state = 'pending';
    if (fixtureCase === 'wrong-canary-base') decision.baseId = 'replacement-base';
    if (fixtureCase === 'wrong-canary-source') decision.sourceId = 'replacement-source';
    if (fixtureCase === 'wrong-canary-table') decision.tableId = 'replacement-table';
    if (fixtureCase === 'wrong-canary-sha') decision.attachment.sha256 = 'a'.repeat(64);
    if (fixtureCase === 'wrong-canary-size') decision.attachment.size = 38;
    if (fixtureCase === 'wrong-canary-mimetype') decision.attachment.mimetype = 'application/json';
    const row = {id:41,run_id:'recovery-canary-v1',decision:JSON.stringify(decision)};
    if (url.searchParams.has('where')) {
      if (fixtureCase === 'missing-canary') return json({list:[],pageInfo:{totalRows:0,isLastPage:true}});
      if (fixtureCase === 'duplicate-canary') return json({list:[row,row],pageInfo:{totalRows:2,isLastPage:true}});
      return json({list:[row],pageInfo:{totalRows:1,isLastPage:true}});
    }
    return json({list:[row]});
  }
  if (url.pathname === '/api/v2/meta/comments' && method === 'GET') {
    const attachment = {id:'attachment-canary',path:canaryPath,title:'issue334-recovery-canary-v1.txt',mimetype:'text/plain',size:37};
    if (fixtureCase === 'wrong-comment') attachment.id = 'replacement-attachment';
    return json({list:[{id:'comment-canary',base_id:'base-acceptance',source_id:'source-operator',
      fk_model_id:'table-decision',row_id:'41',comment:'issue334-recovery-canary-v1',attachments:[attachment]}]});
  }
  if (url.pathname === `/${canaryPath}` && method === 'GET') {
    return new Response(fixtureCase === 'wrong-bytes' ? new TextEncoder().encode('wrong') : canaryBytes, {status:200});
  }
  throw new Error(`unexpected_fixture_request:${method}:${url.pathname}${url.search}`);
};
EOF

failures=0
record_failure() {
	echo "NocoDB restore request test failed: $*" >&2
	failures=$((failures + 1))
}

run_case() { # <case>
	local case_name="$1" status output events
	output="$fixture/$case_name.log"
	events="$fixture/$case_name.events"
	: >"$events"
	set +e
	NOCODB_RESTORE_REQUEST_CASE="$case_name" NOCODB_RESTORE_REQUEST_EVENTS="$events" \
		APP_SERVICE='nc-restore-fixture-nocodb' RUN_HASH='0123456789ab' \
		SOURCE_REGISTRY='{"items":[{"domain":"issue334_acceptance","accessKind":"reader","baseId":"base-acceptance","sourceId":"source-reader","integrationId":"integration-reader","state":"ready","valid":true},{"domain":"issue334_acceptance","accessKind":"operator","baseId":"base-acceptance","sourceId":"source-operator","integrationId":"integration-operator","state":"ready","valid":true}]}' \
		ADMIN_EMAIL='fixture-admin@example.invalid' ADMIN_PASSWORD='fixture-password-not-a-secret' \
		NODE_OPTIONS="--import=$fixture/mock-fetch.mjs" \
		mise exec -- node --input-type=module --eval "$request_script" >"$output" 2>&1
	status="$?"
	set -e
	if rg -Fq 'fixture-password-not-a-secret' "$output" || rg -Fq 'fixture.jwt-token' "$output"; then
		record_failure "$case_name exposed secret-bearing fixture values"
	fi
	printf '%s\t%s\t%s\t%s\n' "$case_name" "$status" "$output" "$events"
}

IFS=$'\t' read -r case_name status output events < <(run_case valid)
[[ "$status" -eq 0 ]] || record_failure "valid producer canary failed: $(tail -n 1 "$output")"
[[ "$(tail -n 1 "$output")" == nocodb_restore_assertions=passed ]] ||
	record_failure 'valid producer canary omitted bounded success evidence'
rg -q '^GET /api/v2/tables/table-decision/records\?.*where=.*recovery-canary-v1' "$events" ||
	record_failure 'consumer did not query the fixed recovery-canary row'
rg -q '^GET /api/v2/meta/comments\?.*fk_model_id=table-decision.*row_id=41' "$events" ||
	record_failure 'consumer did not query the exact canary comment association'
rg -Fxq "GET /download/issue334_acceptance/recovery-canary-v1/issue334-recovery-canary-v1_abcD1.txt" "$events" ||
	record_failure 'consumer did not download the canonical internal canary path'

for rejected_case in missing-canary extra-canary-key external-canary-path wrong-saved-view \
	wrong-view-id wrong-view-title wrong-view-type wrong-comment wrong-bytes wrong-integration \
	pending-canary wrong-canary-base wrong-canary-source wrong-canary-table wrong-canary-sha \
	wrong-canary-size wrong-canary-mimetype duplicate-canary; do
	IFS=$'\t' read -r case_name status output events < <(run_case "$rejected_case")
	[[ "$status" -ne 0 ]] || record_failure "$case_name producer-contract violation was accepted"
done

[[ "$failures" -eq 0 ]] || exit 1
echo 'NocoDB restore request tests passed.'

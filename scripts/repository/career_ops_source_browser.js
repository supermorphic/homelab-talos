async (options) => {
  // Browser-only producer. Execute through browser_evaluate with filename set
  // to the native receiver's FIFO. NEVER return this result to a chat transcript.
  // Forgejo 15.0.9 settings form and server readback are the authority for scope.
  const origin = 'https://forgejo.infra.supermorphic.com';
  const repository = 'supermorphic/career-ops';
  const settings = '/user/settings/applications';
  const preparation = options.preparation === true;
  const pendingKey = preparation ? '__careerOpsPreparationEnrollment' : '__careerOpsSourceEnrollment';
  const confirmation = preparation ? 'enroll:career-ops:preparation-source' : 'enroll:career-ops:flux-source';
  const namePattern = preparation ? /^career-ops-prepare-[a-z0-9-]{1,64}$/ : /^career-ops-flux-[a-z0-9-]{1,64}$/;
  const stop = () => { throw new Error('Enrollment stopped'); };
  try {
    if (location.origin !== origin || options.origin !== origin ||
        options.repository !== repository ||
        options.confirmation !== confirmation ||
        (options.preparation !== undefined && typeof options.preparation !== 'boolean') ||
        !namePattern.test(options.tokenName)) stop();
    const request = async (path, args = {}, expected = path) => {
      const response = await fetch(origin + path, {
        credentials: 'same-origin', redirect: 'follow',
        signal: AbortSignal.timeout(20000), ...args,
      });
      if (!response.ok || response.url !== origin + expected) stop();
      return response;
    };
    const parse = (html) => new DOMParser().parseFromString(html, 'text/html');
    const verify = async (receipt) => {
      const bound = await (await request('/api/v1/repos/' + repository,
        {credentials: 'omit', headers: {Authorization: 'token ' + receipt.password}})).json();
      if (bound.id !== 3 || bound.full_name !== repository || bound.private !== true) stop();
      window[pendingKey].verified = true;
      return receipt;
    };
    if (window[pendingKey]) {
      const pending = window[pendingKey];
      if (pending.token?.name !== options.tokenName) stop();
      const {verified, ...receipt} = pending;
      return await verify(receipt);
    }
    if (options.resumeOnly) stop();
    const profile = parse(await (await request('/user/settings')).text());
    const username = profile.querySelector('input[name="name"]')?.value;
    if (!username || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/.test(username)) stop();
    const before = parse(await (await request(settings)).text());
    const rows = (document) => Array.from(document.querySelectorAll('.flex-item'))
      .filter((row) => row.querySelector('.flex-item-title')?.textContent.trim() === options.tokenName);
    if (rows(before).length) stop(); // Existing raw tokens cannot be retrieved.
    const formDocument = parse(await (await request(settings + '/tokens/new')).text());
    const form = formDocument.querySelector('#scoped-access-form');
    if (!form || form.getAttribute('action') !== settings + '/tokens/new') stop();
    const body = new URLSearchParams({name: options.tokenName, resource: 'repo-specific',
      selected_repo: repository, scope: 'read:repository'});
    // Preserve a hidden CSRF field when the server provides one. Native browser
    // requests also retain its session cookies and same-origin request headers.
    const csrf = formDocument.querySelector('input[name="_csrf"]');
    if (csrf) body.set('_csrf', csrf.value);
    // No retry: a lost creation response has an uncertain server outcome.
    const created = parse(await (await request(settings + '/tokens/new',
      {method: 'POST', body}, settings)).text());
    const password = created.querySelector('.flash-info p')?.textContent.trim();
    const matches = rows(created);
    if (!password || !/^[a-f0-9]{40}$/.test(password) || matches.length !== 1) stop();
    const row = matches[0];
    const id = Number(row.querySelector('[data-modal-id="delete-token"]')?.getAttribute('data-id'));
    const lists = Array.from(row.querySelectorAll('details ul'));
    // Repository-specific tokens have a repository list followed by a scope list.
    // Tokens for all repositories have only the scope list and are rejected.
    if (!Number.isSafeInteger(id) || id <= 0 || lists.length !== 2) stop();
    const repos = Array.from(lists[0].querySelectorAll('li a'));
    const scopes = Array.from(lists[1].querySelectorAll('li')).map((item) => item.textContent.trim());
    if (repos.length !== 1 || repos[0].textContent.trim() !== repository ||
        new URL(repos[0].getAttribute('href'), origin).href !== origin + '/' + repository ||
        scopes.length !== 1 || scopes[0] !== 'read:repository') stop();
    const receipt = {origin, username, password,
      token: {id, name: options.tokenName, scopes, repositories: [repository]}};
    // Keep the one-time receipt in browser memory for a sealing retry. Never put
    // it in the page DOM, console, storage, a screenshot, or a regular file.
    window[pendingKey] = {...receipt, verified: false};
    return await verify(receipt);
  } catch {
    return {error: 'Source enrollment stopped. Inspect account authentication and token metadata; do not retry creation automatically.'};
  }
}

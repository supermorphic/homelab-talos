# Homepage custom icons

`allure.svg` is the unmodified official Allure 3 report logo vendored from:

- Repository: `https://github.com/allure-framework/allure3`
- Commit: `fe2ea92eaab4e409a3c8cf52ba96e35df96b2298`
- Original path: `packages/web-components/src/assets/svg/report-logo.svg`
- Permalink: `https://github.com/allure-framework/allure3/blob/fe2ea92eaab4e409a3c8cf52ba96e35df96b2298/packages/web-components/src/assets/svg/report-logo.svg`

Kustomize stores this asset in the `homepage-icons` ConfigMap. The Homepage
Deployment mounts that single file at `/app/public/icons/allure.svg`.

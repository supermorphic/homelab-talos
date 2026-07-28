// Homepage v1.13.2 supports these Portainer Kubernetes fields but does not
// include their English translations. Replace only the three raw i18n keys so
// the long "PORTAINER." prefix cannot overflow the mobile widget blocks.
(() => {
  const portainerLabels = new Map([
    ["portainer.applications", "Applications"],
    ["portainer.services", "Services"],
    ["portainer.namespaces", "Namespaces"],
  ]);

  const relabelTextNode = (node) => {
    const replacement = portainerLabels.get(node.textContent.trim().toLowerCase());
    if (replacement) {
      node.textContent = replacement;
    }
  };

  const relabel = (root) => {
    if (root.nodeType === Node.TEXT_NODE) {
      relabelTextNode(root);
      return;
    }

    if (
      root.nodeType !== Node.ELEMENT_NODE &&
      root.nodeType !== Node.DOCUMENT_FRAGMENT_NODE
    ) {
      return;
    }

    const textNodes = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    while (textNodes.nextNode()) {
      relabelTextNode(textNodes.currentNode);
    }
  };

  const start = () => {
    relabel(document.body);

    new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.type === "characterData") {
          relabelTextNode(mutation.target);
          continue;
        }

        for (const node of mutation.addedNodes) {
          relabel(node);
        }
      }
    }).observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
    });
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();

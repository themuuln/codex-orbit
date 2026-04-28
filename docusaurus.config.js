// @ts-check

const isVercel =
  process.env.DOCS_DEPLOY_TARGET === "vercel" || process.env.VERCEL === "1";
const vercelHost =
  process.env.VERCEL_PROJECT_PRODUCTION_URL || process.env.VERCEL_URL || "codex-orbit.vercel.app";

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "Codex Orbit",
  tagline: "Multi-account Codex routing, hot sessions, and provider-local session mirroring.",
  favicon: "img/favicon.svg",
  url: isVercel ? `https://${vercelHost}` : "https://themuuln.github.io",
  baseUrl: isVercel ? "/" : "/codex-orbit/",
  organizationName: "themuuln",
  projectName: "codex-orbit",
  deploymentBranch: "gh-pages",
  trailingSlash: false,
  onBrokenLinks: "throw",
  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: "throw",
    },
  },
  presets: [
    [
      "classic",
      {
        docs: {
          routeBasePath: "/",
          sidebarPath: require.resolve("./sidebars.js"),
          editUrl: "https://github.com/themuuln/codex-orbit/tree/main/",
        },
        blog: false,
        pages: false,
        theme: {
          customCss: require.resolve("./src/css/custom.css"),
        },
      },
    ],
  ],
  themeConfig: {
    image: "img/social-card.svg",
    navbar: {
      title: "Codex Orbit",
      items: [
        {
          type: "docSidebar",
          sidebarId: "docsSidebar",
          position: "left",
          label: "Docs",
        },
        {
          href: "https://github.com/themuuln/codex-orbit",
          label: "GitHub",
          position: "right",
        },
      ],
    },
    footer: {
      style: "dark",
      links: [
        {
          title: "Docs",
          items: [
            {label: "Overview", to: "/"},
            {label: "Session Router", to: "/session-router"},
            {label: "Publishing", to: "/publishing"},
          ],
        },
        {
          title: "Project",
          items: [
            {label: "Repository", href: "https://github.com/themuuln/codex-orbit"},
            {label: "Releases", href: "https://github.com/themuuln/codex-orbit/releases"},
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Codex Orbit.`,
    },
    prism: {
      additionalLanguages: ["bash", "json", "toml"],
    },
  },
};

module.exports = config;

#!/usr/bin/env python3

import argparse
import pathlib
import sys


TEMPLATE = """class CodexOrbit < Formula
  desc "Round-robin launcher for multiple Codex CLI accounts"
  homepage "https://github.com/themuuln/codex-orbit"
  url "{url}"
  sha256 "{sha256}"

  depends_on "python@3.13"
  depends_on "ripgrep"
  depends_on "zsh" unless OS.mac?

  def install
    (libexec/"bin").install "bin/cx"
    (libexec/"libexec").install "libexec/codex-orbit.zsh",
                              "libexec/codex-orbit-quota.py",
                              "libexec/codex-orbit-share.py",
                              "libexec/codex-orbit-shared-home.py"

    python_path = Formula["python@3.13"].opt_libexec/"bin"
    (bin/"cx").write <<~SH
      #!/bin/sh
      export PATH="#{{python_path}}:$PATH"
      export CODEX_ORBIT_LIBEXEC_DIR="#{{libexec}}/libexec"
      exec "#{{libexec}}/bin/cx" "$@"
    SH
    chmod 0755, bin/"cx"

    (share/"codex-orbit").mkpath
    (share/"codex-orbit"/"codex-orbit.zsh").write <<~SH
      typeset -g CODEX_ORBIT_LIBEXEC_DIR="#{{libexec}}/libexec"
      source "#{{libexec}}/libexec/codex-orbit.zsh"
    SH
  end

  test do
    assert_match "Usage: cx", shell_output("#{{bin}}/cx --help")
    assert_match "Usage: cx share", shell_output("#{{bin}}/cx share --help")
    assert_predicate share/"codex-orbit/codex-orbit.zsh", :exist?
    assert_match "Usage: cx", shell_output("zsh -lc 'source #{{share}}/codex-orbit/codex-orbit.zsh && cx --help'")
  end
end
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rendered = TEMPLATE.format(url=args.url, sha256=args.sha256)
    if args.output:
        path = pathlib.Path(args.output)
        path.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

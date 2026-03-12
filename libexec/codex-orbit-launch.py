#!/usr/bin/env python3

import argparse
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import tty


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--account-dir", required=True)
    parser.add_argument("--initial-command", default="")
    parser.add_argument("--min-wait-seconds", type=float, default=2.5)
    parser.add_argument("--quiet-period-seconds", type=float, default=1.0)
    parser.add_argument("--max-wait-seconds", type=float, default=8.0)
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    return parser.parse_args()


def get_winsize(fd):
    packed = fcntl.ioctl(fd, termios.TIOCGWINSZ, struct.pack("HHHH", 0, 0, 0, 0))
    return struct.unpack("HHHH", packed)


def set_winsize(fd, winsize):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", *winsize))


def should_send_initial_command(
    initial_command,
    sent_initial_command,
    user_interacted,
    saw_output,
    last_output_at,
    started_at,
    min_wait_seconds,
    quiet_period_seconds,
    max_wait_seconds,
):
    if not initial_command or sent_initial_command or user_interacted:
        return False

    now = time.monotonic()
    elapsed = now - started_at
    if elapsed >= max_wait_seconds:
        return True

    if elapsed < min_wait_seconds or not saw_output or last_output_at is None:
        return False

    return (now - last_output_at) >= quiet_period_seconds


def main():
    args = parse_args()
    cmd = list(args.cmd)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print("missing command to launch", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env["CODEX_HOME"] = args.account_dir

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    use_raw_mode = os.isatty(stdin_fd)
    original_tty = None
    previous_sigwinch = None

    master_fd, slave_fd = pty.openpty()

    if os.isatty(stdin_fd):
        try:
            set_winsize(slave_fd, get_winsize(stdin_fd))
        except OSError:
            pass

    process = subprocess.Popen(
        cmd,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        env=env,
    )
    os.close(slave_fd)

    def handle_sigwinch(signum, frame):
        del signum, frame
        if not os.isatty(stdin_fd):
            return
        try:
            set_winsize(master_fd, get_winsize(stdin_fd))
        except OSError:
            pass

    try:
        if use_raw_mode:
            original_tty = termios.tcgetattr(stdin_fd)
            tty.setraw(stdin_fd)
            previous_sigwinch = signal.getsignal(signal.SIGWINCH)
            signal.signal(signal.SIGWINCH, handle_sigwinch)

        sent_initial_command = False
        user_interacted = False
        saw_output = False
        last_output_at = None
        started_at = time.monotonic()

        while True:
            if should_send_initial_command(
                initial_command=args.initial_command,
                sent_initial_command=sent_initial_command,
                user_interacted=user_interacted,
                saw_output=saw_output,
                last_output_at=last_output_at,
                started_at=started_at,
                min_wait_seconds=args.min_wait_seconds,
                quiet_period_seconds=args.quiet_period_seconds,
                max_wait_seconds=args.max_wait_seconds,
            ):
                os.write(master_fd, args.initial_command.encode("utf-8") + b"\r")
                sent_initial_command = True

            read_fds = [master_fd]
            if process.poll() is None:
                read_fds.append(stdin_fd)

            ready, _, _ = select.select(read_fds, [], [], 0.1)

            if master_fd in ready:
                try:
                    data = os.read(master_fd, 8192)
                except OSError:
                    data = b""

                if data:
                    os.write(stdout_fd, data)
                    saw_output = True
                    last_output_at = time.monotonic()
                elif process.poll() is not None:
                    break

            if stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 1024)
                except OSError:
                    data = b""

                if data:
                    if not sent_initial_command:
                        user_interacted = True
                    os.write(master_fd, data)

            if process.poll() is not None and master_fd not in ready:
                try:
                    trailing = os.read(master_fd, 8192)
                except OSError:
                    trailing = b""
                if trailing:
                    os.write(stdout_fd, trailing)
                break

        return process.wait()
    finally:
        if previous_sigwinch is not None:
            signal.signal(signal.SIGWINCH, previous_sigwinch)
        if original_tty is not None:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, original_tty)
        try:
            os.close(master_fd)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())

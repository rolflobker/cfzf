# cfzf

Some commands are slow, and an old result is often good enough.

Example: `az group list` in the `az` CLI can take a couple of seconds. You want current information, but the output rarely changes. You want to pipe the output to `fzf` and get a fast response, even if that means showing the result of the last run first.

This is where `cfzf` can help.

`cfzf` keeps the last output. The next run opens fzf at once with the old list. A fresh fetch then replaces the list.

Instead of running:

```sh
az group list | fzf
```

You run:

```sh
echo 'az group list' | cfzf
```

cfzf needs the command text to run it and to name its cache.  
The command runs in a new `bash`. It sees exported variables only. It does not see aliases, functions, or unexported variables. Use cfzf in your shell or in scripts.

To prevent showing cached results from different environments, add a key. The key makes the cache unique. A key can be a string, or the output of a command. See [Keys](#keys).

## Quick guide

**1. Install fzf.** It must be on your `PATH`. You need Bash 4.4 or newer. Nothing else is needed.

**2. Load cfzf in bash.** Add this line to `~/.bashrc`:

```bash
source ~/projects/cfzf/cfzf.sh
```

**3. Try it with random lines.** The command waits 3 seconds, then prints 5 lines:

```bash
echo 'sleep 3; for i in $(seq 1 15); do echo "item-$RANDOM"; done' | cfzf
```

The first run shows `Fetching data ...`, then 5 lines. Run it again: the old 5 lines show at once. The header shows the time of the old list and `updating ...`. After about 3 seconds, 5 new lines replace them, and the header shows the new time.

**4. Use a real command.** Pipe the command into cfzf:

```bash
echo 'az group list --query "[].name" -o tsv' | cfzf
```

Every flag after `cfzf` goes to fzf:

```bash
echo 'az group list --query "[].name" -o tsv' | cfzf --height 40% --prompt 'group> '
```

## bkt (optional)

cfzf keeps the old list in a plain file. This is enough for one list.

[bkt](https://github.com/dimo414/bkt) is a cache tool for any command. Use it when other scripts must share the cache: any script can call `bkt -- COMMAND` and reuse the same entry. bkt also expires old data and has more cache key options.

To turn it on:

1. Install it: `cargo install bkt`
2. Add this line to `~/.bashrc`: `export CFZF_BKT=1`

If bkt is missing, cfzf uses the file store. Do not switch one list between the two stores. The next run then opens with an empty list until the fetch ends.

## Keys

Two lists with the same command text can give different results. For example, `az group list` differs per subscription. Set a key per first word in `~/.bashrc`:

```bash
declare -A CFZF_KEYS=(
    [az]='az account show --query id -o tsv'
)
```

cfzf runs the key command on every open. For one call, set the key yourself: `echo 'ls -l' | CFZF_KEY=home cfzf`.

## Cache

cfzf keeps each list in `~/.cache/cfzf`. To clear all lists, run `rm -rf ~/.cache/cfzf`.

The cache holds the command output as plain text. Do not pipe a command that prints secrets into cfzf.

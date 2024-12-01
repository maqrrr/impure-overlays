# impure-overlays

_(aka "what I thought `nix develop` was going to be")_

## Problem

I want to patch a NixOS package and the [workflow described on the wiki](https://nixos.wiki/wiki/Nixpkgs/Create_and_debug_packages) was a lot to understand, written largely for non-flake usage, and didn't work for me to build GNU Hello.

_NOTE: I'm new at nix and it's possible there's a very sensible and idiomatic way to solve this. I would be delighted to find this is all built-in and I've simply misunderstood how to use existing tools._

## Quick start

First, add impure-overlays to local registry so we can refer to it as `impure-overlays#`:

```bash
nix registry add impure-overlays 'github:maqrrr/impure-overlays'
```

### Flake-less example

Make a new temporary directory and try this:

```bash
nix run 'impure-overlays#hello'     # <-- same as 'nixpkgs#hello' for now
nix develop 'impure-overlays#hello' # <-- unpack the source
```

Now you can edit `./overlays/hello/hello-*/src/hello.c`.

Here's my patch, but do your own edit:

```diff
diff --git a/src/hello.c b/src/hello.c
index 2e7d38e..9d62301 100644
--- a/src/hello.c
+++ b/src/hello.c
@@ -163,7 +163,7 @@ main (int argc, char *argv[])
     error (EXIT_FAILURE, errno, _("conversion to a multibyte string failed"));

   /* Print greeting message and exit. */
-  wprintf (L"%ls\n", mb_greeting);
+  wprintf (L"TEST %ls\n", mb_greeting);
   free(mb_greeting);

   exit (EXIT_SUCCESS);
```

Run it and see the patched output!

```console
$ nix run 'impure-overlays#hello'
[impure-overlays] running with /home/user/src/impure-overlays/example/./overlays: [ hello ]
TEST Hello, world!
```

### Flakes template example

Instead of just patching cli tools from nixpkgs, we can patch any nixpkg and use the patch as an overlay in our own flake.

To try this, you can get started with the example template:

```bash
# create demo from template
nix flake new --template 'github:maqrrr/impure-overlays' ./io-example
```

Check out the `flake.nix` created by the template and try these commands from the `./io-example` directory:

```bash
# methods to unpack into ./overlays/<pkg>/source-version/
nix develop '.#overlay.hello.unpack'        # <-- unpack source
nix develop '.#overlay.hello'               # <-- unpack source and get shell

# make an edit to ./overlays/hello/hello-*/src/hello.c to try it out

# method to view diff relative to nixpkgs
nix develop '.#overlay.hello.diff'          # <-- produce a nixpkgs-compatible patch

# methods for building with patched source
nix build --impure '.#overlay.hello'        # <-- build the source with any modifications
nix develop '.#overlay.hello.build'         # <-- same but automatically --impure

# methods for running patched nixpkgs
./result/bin/hello                          # <-- after any of the build methods above
nix run '.#overlay.hello'                   # <-- or run through the flake

# example `apps`
nix run '.#demo'                            # <-- demo app using an unpatched nixpkgs
nix run '.#impureDemo'                      # <-- same app when run with patch applied
```

Note the output of the `diff` commands is compatible with the `patches` section of an overlay.

You can redirect the output to `my-diff.patch`, add that to your flake repo, and use it as an overlay:

```nix
(final: prev: {
  hello = prev.hello.overrideAttrs (oA: rec {
  patches = [ ./my-diff.patch ];
  doCheck = false;
});
```

## Requirements

I don't want to add the full source of whatever I'm patching to my flake's git, just the patch.

The version of the source I want to edit should be the exact source nixpkgs uses to remain compatible as a patch for nixpkgs.

The workflow should be `edit dependency source` --> `re-run thing that depends on it`.

Automated tests should be disabled for the patched package by default.

When my patch works, I need a patch file compatible with the nixpkgs overlay system.

Editing multiple dependent packages and multiple versions at once should work.

When running without a flake, `nix run impure-overlays#pkg` (like `nix run nixpkgs#pkg`) should apply overlays from the local directory and run.

# Known issues

- Not sure if my handling of `system` is correct
- How can I export `mkScript mkApp impureApps` as extra outputs without warnings?
- How can I run the ./test.sh through CI and ideally through `nix flake check`?

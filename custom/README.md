# custom/ — fork-local overrides

Everything in this directory is specific to this fork. It exists so that
tweaks live **beside** upstream code instead of **inside** it, which is what
keeps `git pull upstream develop` from turning into a merge conflict every
release.

## How it works

`ChatwootApp.extensions` (`lib/chatwoot_app.rb`) returns `%w[enterprise custom]`
when this directory is present. The injector in
`config/initializers/01_inject_enterprise_edition_module.rb` walks that list and,
for any class that calls `prepend_mod` / `prepend_mod_with`, prepends a
same-named constant from each namespace if one exists.

So for `app/builders/agent_builder.rb`, which ends with:

```ruby
AgentBuilder.prepend_mod_with('AgentBuilder')
```

...defining `Custom::AgentBuilder` here is enough. No registration step.

Because `custom` comes last in the extensions list, it is prepended last, which
puts it **first** in the ancestor chain:

```
Custom::AgentBuilder -> Enterprise::AgentBuilder -> AgentBuilder
```

Calling `super` walks down that chain, so a `Custom::` override composes with
the enterprise behaviour rather than clobbering it.

## Layout

Mirror `app/`, one level under `custom/app/`:

```
custom/
  app/
    builders/custom/agent_builder.rb   -> Custom::AgentBuilder
    services/custom/...                -> Custom::...
    views/                             -> overrides app/views (unshifted onto view paths)
  lib/
  listeners/
  config/initializers/                 -> required after upstream initializers
```

These paths are registered in `config/application.rb`. That registration is the
**one** upstream file this fork patches — upstream ships the injector and
`ChatwootApp.custom?` but never puts `custom/` on the load path, so without that
patch the `Custom::` constants are defined but never autoloaded.

## Rules of thumb

- **Always call `super`.** An override that does not is a fork of the method's
  whole contract, and it will silently drift as upstream changes.
- **Override the smallest unit that works.** Prefer wrapping one method over
  redefining a class.
- **Make new behaviour default-off.** Gate on an env var where you can, so the
  app still behaves like stock Chatwoot until deliberately switched on.
- **Only classes that call `prepend_mod` are extensible this way.** Check for
  the call at the bottom of the upstream file first; if it is absent, adding it
  is a one-line upstream patch (and a good upstream PR).

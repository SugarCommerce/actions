# actions

GitHub Actions for the SugarCommerce plugins.

## setup-libraries

The plugins install the SugarCommerce packages from Composer path
repositories:

```json
"repositories": [
  { "type": "path", "url": "../libraries/sugarcommerce/*", "options": { "symlink": false } },
  { "type": "path", "url": "../libraries/edd-registrars", "options": { "symlink": false } }
]
```

Those folders exist on the machine that wrote the lock and nowhere else, so
`composer install` on a runner stops at the first one. This clones them there
first:

```yaml
- uses: actions/checkout@v7

- uses: SugarCommerce/actions/setup-libraries@v1

- run: composer install --prefer-dist --no-progress --no-interaction
```

It reads the plugin's `composer.lock` and, for every package installed from a
path repository whose name is `sugarcommerce/*` or `arraypress/edd-registrars`,
fetches `https://github.com/<vendor>/<name>` into the folder the lock names
(`../libraries/sugarcommerce/money`, `../libraries/edd-registrars`) at the
commit the lock names. That commit is the `dist.reference` of the lock entry:
for a path package Composer records the folder's git `HEAD` there. Each fetch
is one commit deep, and they run eight at a time.

So the build gets the packages the lock was written against, not whatever has
been pushed since. A locked commit that was never pushed fails the step and
says which package.

The checkout is named for the branch in the lock's version (`dev-main` gives
`main`), so Composer reads back the version it recorded.

With no `composer.lock`, it clones what `composer.json` requires, then what
those packages require, at the tip of each repository's default branch, into
the folder the matching path repository points at. A lock entry with no
commit gets the tip too, with a warning.

### Inputs

| Input | Default | |
|---|---|---|
| `working-directory` | `.` | The folder with the plugin's `composer.json` and `composer.lock`. |
| `packages` | `^(sugarcommerce/.+\|arraypress/edd-registrars)$` | Which path packages to clone, as a regular expression over the name. |
| `token` | `github.token` | Reads the repositories. The packages are public, so the default does. |
| `server` | `https://github.com` | Where the repositories live. |

A path package the pattern does not match is left alone, with a warning.

### A plugin checked out somewhere else

Point `working-directory` at it. The folders go where the lock says,
relative to that:

```yaml
- uses: actions/checkout@v7
  with:
    path: wordpress/wp-content/plugins/sugarcart

- uses: SugarCommerce/actions/setup-libraries@v1
  with:
    working-directory: wordpress/wp-content/plugins/sugarcart
```

That puts the packages in `wordpress/wp-content/plugins/libraries/`.

## Releasing

The plugins use `@v1`. After a change that does not break them, move the tag:

```bash
git tag -f v1 && git push -f origin v1
```

## License

GPL-2.0-or-later.

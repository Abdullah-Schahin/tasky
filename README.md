# Docker
A Dockerfile has been provided to run this application.  The default port exposed is 8080.

# Environment Variables
The following environment variables are needed.
|Variable|Purpose|example|
|---|---|---|
|`MONGODB_URI`|Address to mongo server|`mongodb://servername:27017` or `mongodb://username:password@hostname:port` or `mongodb+srv://` schema|
|`SECRET_KEY`|Secret key for JWT tokens|`secret123`|

Alternatively, you can create a `.env` file and load it up with the environment variables.

# Running with Go

Clone the repository into a directory of your choice Run the command `go mod tidy` to download the necessary packages.

You'll need to add a .env file and add a MongoDB connection string with the name `MONGODB_URI` to access your collection for task and user storage.
You'll also need to add `SECRET_KEY` to the .env file for JWT Authentication.

Run the command `go run main.go` and the project should run on `locahost:8080`

# Pre-commit checks

Install `pre-commit` (for example, `brew install pre-commit` on macOS or
`pipx install pre-commit`), then enable the hooks in your clone:

```sh
pre-commit install
pre-commit run --all-files
```

Commits format YAML with pinned Prettier and check whitespace, file endings, YAML/JSON syntax, merge conflicts, large
files, private keys, and AWS credentials matching your local AWS credential file.
Go changes also run `gofmt` and `go vet ./...`; install the Go version required by
`go.mod`. The first run downloads hook environments and may download Go dependencies.
During commits, formatter fixes to staged files are automatically staged again.
Only hook input files that were already fully staged are eligible; unrelated edits
are never added. Pre-commit temporarily hides unstaged changes during commits, so
partially staged files are formatted against their staged content. If restoring
unstaged changes conflicts with formatting, resolve the conflict and retry.
Manual `--all-files` runs may format other files, but do not automatically stage
previously unstaged files or files containing unstaged edits. Review those changes
before staging. Python 3 is required; pre-commit manages the Prettier environment.

The secret hooks do not detect every token or password. The AWS hook skips when
no local AWS credentials exist; CI's TruffleHog scan remains the broader secret check.
Hooks run locally and can be bypassed, so CI checks remain necessary. Each developer
must run `pre-commit install` after cloning. Update pinned hooks with
`pre-commit autoupdate --freeze` and review the resulting changes.

# License

This project is licensed under the terms of the MIT license.

Original project: https://github.com/dogukanozdemir/golang-todo-mongodb

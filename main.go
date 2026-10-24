// Copyright 2015 Matthew Holt and The Caddy Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// This is Caddy's own cmd/caddy/main.go with one more import. Caddy documents this as
// the way to build it with plugins: copy main.go, add the module imports, build. The
// Caddy version and the plugin versions are pinned in go.mod, which Dependabot updates.
package main

import (
	_ "time/tzdata"

	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	// plug in Caddy modules here
	_ "github.com/caddyserver/caddy/v2/modules/standard"

	// plugins of this build; tests/install-test.sh checks that each module ID is listed
	_ "github.com/caddy-dns/cloudflare"
)

func main() {
	caddycmd.Main()
}

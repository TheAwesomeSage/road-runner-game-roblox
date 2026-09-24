# Road Runner Game - Roblox

An endless runner set on a blocky low-poly city street. The runner goes forward
on their own and speeds up over time. You switch between 3 lanes and jump
to dodge rocks and fallen trees, collecting coins along the way.

Built as a [Rojo](https://rojo.space/) project in Luau.

## Controls

| Action      | Keys                  |
| ----------- | --------------------- |
| Move left   | `A` / `Left arrow`    |
| Move right  | `D` / `Right arrow`   |
| Jump        | `Space` / `Up arrow`  |

On touch devices, on-screen buttons appear for each action.

## Running it

Tools are pinned in `rokit.toml` ([Rokit](https://github.com/rojo-rbx/rokit)):

```
rokit install
```

**Live sync into Studio:**

1. Run `rojo serve`.
2. Open a new Baseplate in Roblox Studio and delete the `Baseplate` part.
3. Install the Rojo Studio plugin, then click **Connect**.
4. Press **Play**.

**Or build a place file:**

```
rojo build -o RoadRunner.rbxl
```

Then open `RoadRunner.rbxl` in Studio and press **Play**.

## Project structure

```
src/
  shared/                 ReplicatedStorage.Shared
    RunnerConfig          lanes, speed curve, jump, hitbox (used by server AND client)
  server/                 ServerScriptService.Server
    Main.server           entry point
    ChunkConfig           data: chunk templates, obstacle types, patterns, difficulty
    TerrainChunk          builds chunk template Models, reads their spawn markers
    ChunkManager          rolling window of chunks per runner, pooling
    ObstacleSpawner       fills a chunk's spawn points with obstacles and coins
    PlayerRunner          server-authoritative runner: movement, collision, score
    Pool                  generic instance pool
    Themes/UrbanTheme     all the art (buildings, props, obstacles, coins)
  client/                 StarterPlayerScripts.Client
    RunnerInput.client    key bindings, client prediction, camera, animation
    RunnerHud             distance / coins / crash screen
docs/                     design notes (see docs/ARCHITECTURE.md)
images/                   screenshots and artwork
```

## Customising

All of these are changes to data only; no new scripts are needed.

- **New street segment:** add an entry to `ChunkConfig.Templates`, with its
  buildings, props and road features.
- **New obstacle arrangement:** add a string such as `"T.R"` to
  `ChunkConfig.Patterns`. It is checked at startup, and a pattern that blocks
  every lane is rejected.
- **New obstacle type:** add it to `ChunkConfig.ObstacleTypes` and
  `PatternKeys`. It appears as a plain box until the theme gives it art.
- **Hand-built chunk:** put a Model in `ServerStorage.ChunkTemplates` with
  `Root` and `EndMarker` parts, plus parts tagged `ObstacleSpawn`
  (attributes `Lane`, `Row`) and `CoinSpawn` (attributes `Lane`, `Run`). If it
  shares a name with a config template, it replaces that template.
- **New art style:** copy `Themes/UrbanTheme`, restyle it, and set
  `ChunkConfig.Theme` to the new module's name. Gameplay hitboxes come from
  `ChunkConfig`, so changing the art never changes the difficulty.

## Development

```
selene src          # lint
stylua src          # format
rojo sourcemap -o sourcemap.json   # for luau-lsp type checking
```

## License

Released under the [MIT License](LICENSE).

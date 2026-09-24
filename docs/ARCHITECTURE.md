# Architecture

## Track coordinates

Gameplay never uses world positions directly. Everything is in track
coordinates:

| Axis       | Meaning                                          | World          |
| ---------- | ------------------------------------------------ | -------------- |
| `distance` | studs travelled from the track origin            | `-Z`           |
| `lateral`  | studs from the centre line (lane 1 is leftmost)  | `+X` is right  |
| `height`   | studs above the road surface                     | `+Y`           |

Each player gets their own straight track. Tracks start at
`(slot * TrackSpacing, 0, 0)`, so runners never share or collide with each
other's chunks.

## Server frame (Heartbeat)

For each running player, `PlayerRunner` does the following. Long frames are
split into steps of at most 1/30 s.

1. **Advance.** `distance += SpeedAt(distance) * dt`. Lateral position slides
   toward the target lane at `LaneChangeSpeed`, and the jump arc advances.
2. **`ChunkManager:Update(distance)`.** Spawns chunks ahead first, then
   despawns chunks behind. The order is explained in the ChunkManager header.
3. **Collision.** The runner's box is swept over the distance covered this
   step and tested against each nearby hazard's box. A jumpable hazard counts
   as cleared if the runner's feet are above its top.
4. **Coins.** The same swept test, with a pickup radius added.
5. **Place the character.** The HumanoidRootPart is anchored, and the server
   sets its CFrame.
6. **Publish** the runner state as Player attributes.

## Chunk life cycle

```
template (ServerStorage) --Clone--> Pool --Acquire--> placed on previous EndMarker
                                     ^                       |
                                     |               ObstacleSpawner:Populate
                                     |                       |
                                     +--Release-- ObstacleSpawner:Clear
                                      (after END is DespawnBehind behind runner)
```

Chunks, obstacles and coins are all pooled. Parked instances stay in
`Workspace.Pooled`, far below the map. Moving them into ServerStorage would
make clients delete and re-download them every time they are reused.

## Obstacle rows and fairness

Each chunk has obstacle rows about 30 studs apart. For each row,
`ObstacleSpawner`:

- rolls whether the row is used at all. The chance rises from 45% to 95% as
  difficulty goes from 0 to 1.
- picks a pattern. Harder patterns unlock at their `MinDifficulty`, and their
  weight grows as difficulty rises.
- rejects any pattern whose open lanes are more than one lane away from every
  open lane in the previous row, even when that row was in the previous
  chunk. This keeps the track passable at top speed.

## Client prediction

The client sends only requests: `LaneChange(direction, seq)` and `Jump()`. So
the game feels instant, `RunnerInput` does the following:

- **Forward:** simulates distance with the same speed curve and blends toward
  the server's `Distance` attribute.
- **Lanes:** shows the server's `Lane` plus any requests the server has not
  acknowledged yet. The server echoes the last sequence number it processed
  in `LaneSeq`.
- **Jumps:** predicts them locally.
- **Rendering:** writes the predicted position to the local character each
  frame, just before rendering, which overrides the replicated server CFrame.

## Known limitations

- **No lag compensation.** The server judges collisions at its own position,
  which trails what the player sees by roughly half their ping. At 100 ms ping
  and top speed, that is about 4 studs. A dodge that is visibly late can still
  count as a crash.
- **Very long runs.** Tracks are not re-centred, so distance grows without a
  limit. Floating-point precision stays fine for runs of tens of thousands of
  studs, about 10 minutes at top speed. Much longer runs would need the track
  shifted back toward the origin.

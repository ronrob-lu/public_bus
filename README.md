# Autonomous Public Bus Mod

This is a Luanti (Minetest) mod that implements an autonomous public bus (`public_bus:bus`) which drives on specific road materials, picks up players dynamically, and follows strict pathfinding rules.

## Node Registration (`public_bus:street`)
A custom solid block featuring a hexagon pattern texture.
It can be crafted using stone with the following recipe:
```
Stone |       | Stone
      | Stone |
Stone |       | Stone
```

## Entity Registration (`public_bus:bus`)
The bus is an autonomous vehicle that:
- Runs at a speed of exactly 4.
- Does not push players or mobs; it stops and waits for them.
- Features right-side driving along the road width.
- Follows pathfinding rules on specified road materials.
- Handles elevations by jumping up 1-block obstacles.
- Turns left at dead ends or walls.
- Accommodates up to 8 players in a 2x4 grid layout.

## Spawn/Access
Buses can only be spawned in Creative Mode or by players with admin (`/grantme all`) privileges.

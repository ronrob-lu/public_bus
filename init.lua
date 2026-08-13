-- Public Bus Mod for Luanti (Minetest)
-- Code licensed under MIT License, Assets under CC BY-SA 4.0.

-- 1. Node Registration (public_bus:street)
minetest.register_node("public_bus:street", {
	description = "Street (Hexagon Pattern)",
	tiles = {"public_bus_street.png"},
	groups = {cracky = 3, stone = 1},
	sounds = (default and default.node_sound_stone_defaults) and default.node_sound_stone_defaults() or nil,
})

-- Craft recipe for public_bus:street
-- stone, empty, stone
-- empty, stone, empty
-- stone, empty, stone
minetest.register_craft({
	output = "public_bus:street 5",
	recipe = {
		{"default:stone", "", "default:stone"},
		{"", "default:stone", ""},
		{"default:stone", "", "default:stone"},
	}
})

-- 2. Configuration & Allowed Road Materials
local allowed_roads = {
	"default:junglewood",
	"public_bus:street",
	"default:gravel",
	"mg_villages:road",
	"pathv7:stairw"
}

-- Check if a node is an allowed road
local function is_road_node(nodename)
	for _, road in ipairs(allowed_roads) do
		if nodename == road then
			return true
		end
	end
	return false
end

-- Helper: Check if a node is solid (walkable)
local function is_solid(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then return true end -- treat unloaded as solid/impassable
	if is_road_node(node.name) then return true end -- roads are always considered solid ground for the bus
	local def = minetest.registered_nodes[node.name]
	return def and def.walkable
end

-- Helper: Check if a position has air (empty, non-solid)
local function is_air(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then return false end
	if is_road_node(node.name) then return false end -- roads are never considered air
	local def = minetest.registered_nodes[node.name]
	return not (def and def.walkable)
end

-- Helper: Turn right (90 degrees clockwise)
local function turn_right(dir)
	if dir.z == 1 then
		return {x = 1, y = 0, z = 0} -- North -> East
	elseif dir.x == 1 then
		return {x = 0, y = 0, z = -1} -- East -> South
	elseif dir.z == -1 then
		return {x = -1, y = 0, z = 0} -- South -> West
	elseif dir.x == -1 then
		return {x = 0, y = 0, z = 1} -- West -> North
	end
	return dir
end

-- Helper: Turn left (90 degrees counter-clockwise)
local function turn_left(dir)
	if dir.z == 1 then
		return {x = -1, y = 0, z = 0} -- North -> West
	elseif dir.x == -1 then
		return {x = 0, y = 0, z = -1} -- West -> South
	elseif dir.z == -1 then
		return {x = 1, y = 0, z = 0} -- South -> East
	elseif dir.x == 1 then
		return {x = 0, y = 0, z = 1} -- East -> North
	end
	return dir
end

-- Seating offset configuration for 8 players in a 2x4 grid.
-- In Minetest's set_attach, position is in decimeters (10 units = 1 block).
-- X is left/right (-2.2 is left, 2.2 is right)
-- Y is up (3.5 decimeters above the bus origin/baseline)
-- Z is front/back (from 8.0 in front to -7.0 in back)
-- Scaled by ~3.144647 (the bus mesh is now correctly aligned without the 180-degree yaw rotation).
local seat_offsets = {
	{ x = 0, y = 0, z = 0 }, -- Front-left (Seat 1)
	{ x = 0, y = 0, z = 0 },  -- Front-right (Seat 2)
	{ x = 0, y = 0, z = 0 },  -- Midfront-left (Seat 3)
	{ x = 0, y = 0, z = 0 },   -- Midfront-right (Seat 4)
	{ x = 0, y = 0, z = 0 },  -- Midback-left (Seat 5)
	{ x = 0, y = 0, z = 0 },   -- Midback-right (Seat 6)
	{ x = 0, y = 0, z = 0 }, -- Back-left (Seat 7)
	{ x = 0, y = 0, z = 0 },  -- Back-right (Seat 8)
}

-- ============================================================================
-- NEW STRICT MOVEMENT AND PATHFINDING
-- ============================================================================

-- Check if a position contains valid road material
local function is_road_at_pos(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then return false end
	return is_road_node(node.name)
end

-- Helper: Get the valid road Y coordinate at (px, pz) near current_y
-- Returns current_y, current_y + 1, current_y - 1, or nil if no valid road
local function get_valid_road_y(px, pz, current_y)
	-- Check flat (current_y)
	local pos_flat = {x = px, y = current_y, z = pz}
	local pos_flat_air = {x = px, y = current_y + 1, z = pz}
	if is_road_at_pos(pos_flat) and is_air(pos_flat_air) then
		return current_y
	end

	-- Check up (current_y + 1)
	local pos_up = {x = px, y = current_y + 1, z = pz}
	local pos_up_air = {x = px, y = current_y + 2, z = pz}
	if is_road_at_pos(pos_up) and is_air(pos_up_air) then
		return current_y + 1
	end

	-- Check down (current_y - 1)
	-- To move down, the space we are moving THROUGH must also be air
	local pos_down = {x = px, y = current_y - 1, z = pz}
	local pos_down_air1 = {x = px, y = current_y, z = pz}
	local pos_down_air2 = {x = px, y = current_y + 1, z = pz}
	if is_road_at_pos(pos_down) and is_air(pos_down_air1) and is_air(pos_down_air2) then
		return current_y - 1
	end

	return nil
end

-- Helper: Look ahead to see if the road continues beyond the next block
local function has_valid_next_step(px, pz, py, dir_f)
	local dirs = {
		dir_f,
		turn_left(dir_f),
		turn_right(dir_f)
	}

	for _, d in ipairs(dirs) do
		local nx = px + d.x
		local nz = pz + d.z
		if get_valid_road_y(nx, nz, py) ~= nil then
			return true
		end
	end

	return false
end

-- 3. Entity Registration (public_bus:bus)
minetest.register_entity("public_bus:bus", {
	initial_properties = {
		physical = true,
		-- The physical collision and selection boxes are kept narrow (X limits reduced from
		-- -1.572/1.572 to -1.200/1.200) to ensure the bus fits completely inside standard
		-- 3-block-wide road lanes. This prevents any part of the collision box from overlapping
		-- with the 1-block-high pedestrian sidewalks/sidewalk edges next to the road,
		-- which would otherwise cause the physics engine to step/climb up and drive/fly on top
		-- of the sidewalk.
		collisionbox = {-1.000, 0.000, -10.848, 1.000, 9.435, 9.435},
		selectionbox = {-1.100, 0.000, -11.793, 1.100, 11.322, 10.377},
		visual = "mesh",
		mesh = "new_bus.gltf",
		textures = {"texture_bus_new.png", "colormap.png"},
		visual_size = {x = 30.0, y = 30.0, z = 30.0},
		colors = {},
		spritediv = {x=1, y=1},
		initial_sprite_basepos = {x=0, y=0},
		is_visible = true,
		makes_footstep_sound = false,
		automatic_rotate = 0,
		stepheight = 0.6,
	},

	state = "DRIVING", -- Possible states: "DRIVING", "STOPPED_FOR_MOB", "STOPPED_FOR_PLAYER", "TURNING"
	passengers = {}, -- Array of player names indexed 1 to 8
	yaw = 0,
	speed = 4.0,
	turn_timer = 0,
	turn_cooldown = 0,
	dir_f = nil,

	on_activate = function(self, staticdata, dtime_s)
		self.object:set_armor_groups({fleshy = 100})
		self.passengers = {}
		self.state = "DRIVING"
		self.last_state = "DRIVING"
		self.object:set_animation({x = 1, y = 2}, 1, 0, true)
		self.yaw = self.object:get_yaw() or 0
		self.object:set_yaw(self.yaw)
		self.object:set_acceleration({x = 0, y = -15.0, z = 0}) -- Apply gravity
		self.turn_cooldown = 0
	end,

	get_staticdata = function(self)
		return ""
	end,

	-- Support punch to board/exit
	on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir)
		if not puncher or not puncher:is_player() then
			return
		end
		local name = puncher:get_player_name()
		local has_privs = minetest.check_player_privs(name, {give = true}) or minetest.check_player_privs(name, {server = true})
		local is_creative = minetest.settings:get_bool("creative_mode")

		if not (is_creative or has_privs) then
			minetest.chat_send_player(name, "Only server administrators or players in creative mode can destroy this bus!")
			return
		end

		-- Detach all passengers
		for seat_idx, passenger_name in pairs(self.passengers) do
			local passenger = minetest.get_player_by_name(passenger_name)
			if passenger then
				passenger:set_detach()
				passenger:set_eye_offset({x=0, y=0, z=0}, {x=0, y=0, z=0})
				passenger:set_properties({visual_size = {x=1, y=1, z=1}})
			end
		end

		-- Give spawner item if not in creative mode
		if not is_creative then
			local inv = puncher:get_inventory()
			local stack = ItemStack("public_bus:bus_spawner")
			if inv and inv:room_for_item("main", stack) then
				inv:add_item("main", stack)
			else
				minetest.add_item(self.object:get_pos() or puncher:get_pos(), stack)
			end
		end

		-- Remove the entity
		self.object:remove()
	end,

	-- Support right-click to board/exit (clicking)
	on_rightclick = function(self, clicker)
		if not clicker or not clicker:is_player() then
			return
		end
		local name = clicker:get_player_name()

		-- If already attached, detach
		for seat_idx, passenger_name in pairs(self.passengers) do
			if passenger_name == name then
				clicker:set_detach()
				self.passengers[seat_idx] = nil
				clicker:set_eye_offset({x=0, y=0, z=0}, {x=0, y=0, z=0})
				clicker:set_properties({visual_size = {x=1, y=1, z=1}})
				return
			end
		end

		-- Otherwise, try to attach
		for i = 1, 8 do
			if not self.passengers[i] then
				self.passengers[i] = name
				local seat = seat_offsets[i]
					-- Since the bus's visual_size is scaled 30x, the passenger is rendered
					-- at seat_offset * 30, but the passenger camera is not scaled.
					-- We shift the first-person and third-person eye offset by seat * 29
				-- (and add y=10 for the default height) to align the camera perfectly
					-- with the passenger's 30x scaled seating position.
				-- The passenger is now facing forward (0 rotation) relative to the bus.
				local eye_offset = {
						x = seat.x * 29.0,
						y = seat.y * 29.0 + 17.0,
						z = seat.z * 29.0
				}
				clicker:set_attach(self.object, "", seat, {x=0, y=0, z=0})
				clicker:set_eye_offset(eye_offset, eye_offset)
					clicker:set_properties({visual_size = {x=1/30, y=1/30, z=1/30}})
				return
			end
		end

		minetest.chat_send_player(name, "The bus is full!")
	end,

	update_bus_boxes = function(self)
		if not self.dir_f then return end
		local cbox, sbox
		if self.dir_f.x ~= 0 then
			-- Facing East or West (X axis). Swap width and length.
			-- Original: {-1.000, 0.000, -10.848, 1.000, 9.435, 9.435}
			-- Swapped: {-10.848, 0.000, -1.000, 9.435, 9.435, 1.000} (min/max fixed)
			cbox = {-10.848, 0.000, -1.000, 9.435, 9.435, 1.000}
			sbox = {-11.793, 0.000, -1.100, 10.377, 11.322, 1.100}
		else
			-- Facing North or South (Z axis). Use original bounds.
			cbox = {-1.000, 0.000, -10.848, 1.000, 9.435, 9.435}
			sbox = {-1.100, 0.000, -11.793, 1.100, 11.322, 10.377}
		end
		self.object:set_properties({
			collisionbox = cbox,
			selectionbox = sbox
		})
	end,

	-- ========================================================================
	-- STRICT STATE MACHINE & PATHFINDING INSIDE on_step
	-- ========================================================================
	on_step = function(self, dtime)
		local pos = self.object:get_pos()
		if not pos then return end

		-- 1. Synchronize passengers (remove any who detached manually or logged off)
		for i = 1, 8 do
			local pname = self.passengers[i]
			if pname then
				local player = minetest.get_player_by_name(pname)
				if not player then
					self.passengers[i] = nil
				else
					local parent = player:get_attach()
					if parent ~= self.object then
						self.passengers[i] = nil
						player:set_eye_offset({x=0, y=0, z=0}, {x=0, y=0, z=0})
						player:set_properties({visual_size = {x=1, y=1, z=1}})
					end
				end
			end
		end

		-- Ensure dir_f is initialized and strictly aligned
		if not self.dir_f then
			local yaw = self.object:get_yaw() or 0
			local dir = minetest.yaw_to_dir(yaw)
			if math.abs(dir.x) > math.abs(dir.z) then
				self.dir_f = {x = dir.x > 0 and 1 or -1, y = 0, z = 0}
			else
				self.dir_f = {x = 0, y = 0, z = dir.z > 0 and 1 or -1}
			end
			self.yaw = minetest.dir_to_yaw(self.dir_f)
			self.object:set_yaw(self.yaw)
			self:update_bus_boxes()
		end

		-- 2. Player and Mob Detection in front of the bus
		local front_center = {
			x = pos.x + self.dir_f.x * 15.45,
			y = pos.y + 0.5,
			z = pos.z + self.dir_f.z * 15.45
		}
		local objects = minetest.get_objects_inside_radius(front_center, 6.0)
		local obstacle_player = nil
		local obstacle_mob = nil

		for _, obj in ipairs(objects) do
			if obj ~= self.object then
				local is_passenger = false
				if obj:is_player() then
					local pname = obj:get_player_name()
					for _, passenger_name in pairs(self.passengers) do
						if passenger_name == pname then
							is_passenger = true
							break
						end
					end
					if not is_passenger then
						obstacle_player = obj
						break
					end
				else
					-- Check if it is a mob or NPC
					local luaent = obj:get_luaentity()
					if luaent and luaent.name ~= "__builtin:item" and luaent.name ~= "__builtin:falling_node" then
						obstacle_mob = obj
						break
					end
				end
			end
		end

		if obstacle_player then
			self.state = "STOPPED_FOR_PLAYER"
		elseif obstacle_mob then
			self.state = "STOPPED_FOR_MOB"
		elseif self.state == "STOPPED_FOR_PLAYER" or self.state == "STOPPED_FOR_MOB" then
			self.state = "DRIVING"
		end

		if self.state ~= self.last_state then
			if self.state == "DRIVING" or self.state == "TURNING" then
				self.object:set_animation({x = 1, y = 2}, 1, 0, true)
			else
				self.object:set_animation({x = 0, y = 0.59}, 1, 0, true)
			end
			self.last_state = self.state
		end

		if self.state == "STOPPED_FOR_PLAYER" or self.state == "STOPPED_FOR_MOB" then
			local vel = self.object:get_velocity() or {x=0, y=0, z=0}
			self.object:set_velocity({x = 0, y = 0, z = 0})
			return
		end

		-- TURNING state
		if self.state == "TURNING" then
			self.object:set_velocity({x = 0, y = 0, z = 0})

			self.turn_timer = self.turn_timer + dtime
			if self.turn_timer >= 0.5 then
				self.turn_timer = 0
				self.dir_f = self.pending_turn_dir
				self.yaw = minetest.dir_to_yaw(self.dir_f)
				self.object:set_yaw(self.yaw)
				self:update_bus_boxes()

				local new_pos = self.object:get_pos()
				new_pos.x = math.floor(new_pos.x + 0.5)
				new_pos.z = math.floor(new_pos.z + 0.5)
				self.object:set_pos(new_pos)

				self.state = "DRIVING"
					if self.state ~= self.last_state then
						self.object:set_animation({x = 1, y = 2}, 1, 0, true)
						self.last_state = self.state
					end
			end
			return
		end

		-- DRIVING state
		if self.state == "DRIVING" then
			-- Snap to axis to prevent drifting
			local needs_snap = false
			if self.dir_f.x ~= 0 then
				local snapped_z = math.floor(pos.z + 0.5)
				if math.abs(pos.z - snapped_z) > 0.05 then
					pos.z = snapped_z
					needs_snap = true
				end
			elseif self.dir_f.z ~= 0 then
				local snapped_x = math.floor(pos.x + 0.5)
				if math.abs(pos.x - snapped_x) > 0.05 then
					pos.x = snapped_x
					needs_snap = true
				end
			end
			if needs_snap then
				self.object:set_pos(pos)
			end

			-- PART 1: Fix the "Flying" Issue (100% Gravity)
			-- Find the actual ground level directly BELOW the bus by checking downwards
			-- Start from current rounded Y and go down up to 5 blocks to find a solid block
			local ground_y = math.floor(pos.y + 0.5)
			local found_ground = false
			for y_search = math.floor(pos.y + 0.5), math.floor(pos.y + 0.5) - 5, -1 do
				local check_pos = {
					x = math.floor(pos.x + 0.5),
					y = y_search,
					z = math.floor(pos.z + 0.5)
				}
				if is_solid(check_pos) then
					ground_y = y_search
					found_ground = true
					break
				end
			end

			if found_ground then
				-- Force the bus's Y position (height) to be exactly on top of that solid block.
				pos.y = ground_y + 0.5
				self.object:set_pos(pos)
			end

			-- Force the bus's Y velocity (up/down speed) to be exactly 0.
			local vel = self.object:get_velocity() or {x=0, y=0, z=0}
			vel.y = 0
			self.object:set_velocity(vel)

			-- PART 3: Smart Pathfinding with Lookahead
			local target_x = math.floor(pos.x + self.dir_f.x + 0.5)
			local target_z = math.floor(pos.z + self.dir_f.z + 0.5)

			local next_y = get_valid_road_y(target_x, target_z, ground_y)

			if next_y ~= nil then
				-- We found a valid road block directly in front of us (flat, up, or down).
				-- Now we must look ahead to ensure the road goes further, so we don't get stuck in a hole or a 1-block dead end.
				if has_valid_next_step(target_x, target_z, next_y, self.dir_f) then
					-- The road continues safely. Move forward.
					if next_y > ground_y then
						-- Step up
						pos.x = target_x
						pos.y = pos.y + 1
						pos.z = target_z
						self.object:set_pos(pos)
					end
					-- No need to explicitly step down here, the gravity check at the beginning of DRIVING state will drop it down.

					self.object:set_velocity({x = self.dir_f.x * 4.0, y = 0, z = self.dir_f.z * 4.0})
					return
				end
			end

			-- If next_y is nil OR the road does not continue (dead end / single block hole),
			-- stop and turn left to find another way.
			self.object:set_velocity({x = 0, y = 0, z = 0})
			self.pending_turn_dir = turn_left(self.dir_f)
			self.state = "TURNING"
			if self.state ~= self.last_state then
				self.object:set_animation({x = 1, y = 2}, 1, 0, true)
				self.last_state = self.state
			end
			self.turn_timer = 0
			return
		end
	end
})

-- 4. Bus Spawner Craftitem (Creative mode or Admin/Server-privileged only)
minetest.register_craftitem("public_bus:bus_spawner", {
	description = "Autonomous Public Bus Spawner",
	inventory_image = "public_bus_inv.png",
	on_place = function(itemstack, placer, pointed_thing)
		if not placer or not placer:is_player() then
			return itemstack
		end

		local name = placer:get_player_name()
		local has_privs = minetest.check_player_privs(name, {give = true}) or minetest.check_player_privs(name, {server = true})
		local is_creative = minetest.settings:get_bool("creative_mode")

		if not (is_creative or has_privs) then
			minetest.chat_send_player(name, "You need creative mode or admin rights to spawn the autonomous bus!")
			return itemstack
		end

		if pointed_thing.type == "node" then
			local pos = pointed_thing.above
			pos.x = math.floor(pos.x + 0.5)
			pos.y = pos.y + 0.1
			pos.z = math.floor(pos.z + 0.5)
			local ent = minetest.add_entity(pos, "public_bus:bus")
			if ent then
				local yaw = placer:get_look_horizontal()
				local luaent = ent:get_luaentity()
				if luaent then
					-- Align dir_f to closest cardinal direction
					local dir_f = minetest.yaw_to_dir(yaw)
					if math.abs(dir_f.x) > math.abs(dir_f.z) then
						luaent.dir_f = {x = dir_f.x > 0 and 1 or -1, y = 0, z = 0}
					else
						luaent.dir_f = {x = 0, y = 0, z = dir_f.z > 0 and 1 or -1}
					end

					luaent.yaw = minetest.dir_to_yaw(luaent.dir_f)
					ent:set_yaw(luaent.yaw)
					luaent:update_bus_boxes()
				else
					ent:set_yaw(yaw)
				end
				if not is_creative then
					itemstack:take_item()
				end
			end
		end
		return itemstack
	end,
})

-- 5. Chat Command to Clear All Buses
minetest.register_chatcommand("clear_pbuses", {
	description = "Removes all autonomous public buses on the map",
	privs = {server = true},
	func = function(name, param)
		local count = 0
		for _, entity in pairs(minetest.luaentities) do
			if entity.name == "public_bus:bus" then
				if entity.passengers then
					for _, pname in pairs(entity.passengers) do
						local passenger = minetest.get_player_by_name(pname)
						if passenger then
							passenger:set_detach()
							passenger:set_eye_offset({x=0, y=0, z=0}, {x=0, y=0, z=0})
							passenger:set_properties({visual_size = {x=1, y=1, z=1}})
						end
					end
				end
				entity.object:remove()
				count = count + 1
			end
		end
		return true, "Successfully cleared " .. count .. " public bus(es) from active areas."
	end,
})

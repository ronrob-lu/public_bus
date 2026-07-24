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
	"mg_villages:road"
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
	local def = minetest.registered_nodes[node.name]
	return def and def.walkable
end

-- Helper: Check if a position has air (empty, non-solid)
local function is_air(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then return false end
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
	{ x = -6.918, y = 11.006, z = 25.157 }, -- Front-left (Seat 1)
	{ x = 6.918, y = 11.006, z = 25.157 },  -- Front-right (Seat 2)
	{ x = -6.918, y = 11.006, z = 9.434 },  -- Midfront-left (Seat 3)
	{ x = 6.918, y = 11.006, z = 9.434 },   -- Midfront-right (Seat 4)
	{ x = -6.918, y = 11.006, z = -6.289 },  -- Midback-left (Seat 5)
	{ x = 6.918, y = 11.006, z = -6.289 },   -- Midback-right (Seat 6)
	{ x = -6.918, y = 11.006, z = -22.013 }, -- Back-left (Seat 7)
	{ x = 6.918, y = 11.006, z = -22.013 },  -- Back-right (Seat 8)
}

-- ============================================================================
-- NEW PATHFINDING AND MOVEMENT LOGIC
-- Follows the exact step-by-step rules from the specification.
-- ============================================================================

-- Check if a position contains valid road material
local function is_road_at_pos(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then return false end
	return is_road_node(node.name)
end

-- Get the Y level of road at a horizontal position (searches downward)
local function get_road_y_at_horizontal(x, z, max_search_y)
	for y = max_search_y, max_search_y - 3, -1 do
		local pos = {x = x, y = y, z = z}
		if is_road_at_pos(pos) then
			return y
		end
	end
	return nil
end

-- Main pathfinding function that follows the priority rules
-- Returns: target_pos (x,y,z), should_jump (boolean), direction_to_turn (dir vector or nil)
local function find_path_target(pos, dir_f, dir_r, blocks_since_turn)
	-- Calculate positions relative to bus
	-- Position directly in front of bus at current height (for wall/step detection)
	local front_pos = {
		x = math.floor(pos.x + dir_f.x * 1.5 + 0.5),
		y = math.floor(pos.y + 0.5),
		z = math.floor(pos.z + dir_f.z * 1.5 + 0.5)
	}
	
	-- Position 2 blocks ahead (for checking if road continues straight)
	local ahead_2_pos = {
		x = math.floor(pos.x + dir_f.x * 2.0 + 0.5),
		y = math.floor(pos.y + 0.5),
		z = math.floor(pos.z + dir_f.z * 2.0 + 0.5)
	}
	
	-- Position to the right of the bus
	local right_pos = {
		x = math.floor(pos.x + dir_r.x * 1.5 + 0.5),
		y = math.floor(pos.y + 0.5),
		z = math.floor(pos.z + dir_r.z * 1.5 + 0.5)
	}
	
	-- Position to the left of the bus
	local left_pos = {
		x = math.floor(pos.x - dir_r.x * 1.5 + 0.5),
		y = math.floor(pos.y + 0.5),
		z = math.floor(pos.z - dir_r.z * 1.5 + 0.5)
	}

	-- =========================================================================
	-- PART 1: CHECK FOR 1-BLOCK JUMP (Step Up Logic)
	-- =========================================================================
	-- Check the block directly in front at current height
	local front_node = minetest.get_node(front_pos).name
	local front_is_solid = is_solid(front_pos)
	local front_is_road = is_road_at_pos(front_pos)
	
	-- If front is a solid wall, check for 1-block step up
	if front_is_solid and not front_is_road then
		-- Check block ABOVE the solid block (1 block higher)
		local above_front_pos = {x = front_pos.x, y = front_pos.y + 1, z = front_pos.z}
		local above_is_air = is_air(above_front_pos)
		
		-- Check block ON TOP of that air block (2 blocks higher than original)
		local top_pos = {x = front_pos.x, y = front_pos.y + 2, z = front_pos.z}
		local top_is_road = is_road_at_pos(top_pos)
		
		if above_is_air and top_is_road then
			-- This is a 1-block step up! Return target with Y+1
			local target_x = pos.x + dir_f.x * 1.0
			local target_z = pos.z + dir_f.z * 1.0
			return {x = target_x, y = pos.y + 1, z = target_z}, true, nil
		else
			-- Solid wall, no step possible - stop
			return nil, false, nil
		end
	end
	
	-- If front is empty air (drop-off), do not move forward
	if not front_is_solid and not front_is_road then
		-- Check if there's road below (drop-down situation)
		local below_front_pos = {x = front_pos.x, y = front_pos.y - 1, z = front_pos.z}
		if is_road_at_pos(below_front_pos) then
			-- Allow dropping down 1 block
			local target_x = pos.x + dir_f.x * 1.0
			local target_z = pos.z + dir_f.z * 1.0
			return {x = target_x, y = pos.y - 1, z = target_z}, false, nil
		end
		-- True drop-off - stop
		return nil, false, nil
	end
	
	-- =========================================================================
	-- PART 2: PATHFINDING WITH PRIORITY RULES
	-- =========================================================================
	
	-- Priority 1: Can I go straight?
	-- Check 2 blocks directly in front for valid road material
	local road_ahead_2 = is_road_at_pos(ahead_2_pos)
	
	-- Also check 1 block ahead to be sure
	local ahead_1_pos = {
		x = math.floor(pos.x + dir_f.x * 1.0 + 0.5),
		y = math.floor(pos.y + 0.5),
		z = math.floor(pos.z + dir_f.z * 1.0 + 0.5)
	}
	local road_ahead_1 = is_road_at_pos(ahead_1_pos)
	
	if road_ahead_2 or road_ahead_1 then
		-- KEEP GOING STRAIGHT - ignore sides
		-- Target is 1 block ahead at current Y (or adjust if needed)
		local target_y = pos.y
		-- Check if we need to adjust Y for the target
		if road_ahead_1 then
			target_y = ahead_1_pos.y
		elseif road_ahead_2 then
			target_y = ahead_2_pos.y
		end
		
		local target_x = pos.x + dir_f.x * 1.0
		local target_z = pos.z + dir_f.z * 1.0
		return {x = target_x, y = target_y, z = target_z}, false, nil
	end
	
	-- No road straight ahead - check if we're in turning cooldown
	-- During cooldown, don't check sides, just try to go forward
	if blocks_since_turn and blocks_since_turn < 4 then
		-- Still in cooldown, try to move forward even without road detection
		-- This helps complete the turn away from intersection
		local target_x = pos.x + dir_f.x * 1.0
		local target_z = pos.z + dir_f.z * 1.0
		return {x = target_x, y = pos.y, z = target_z}, false, nil
	end
	
	-- Priority 2: Can I turn right?
	local road_right = is_road_at_pos(right_pos)
	if road_right then
		-- Turn right
		local right_dir = turn_right(dir_f)
		return nil, false, right_dir
	end
	
	-- Priority 3: Can I turn left?
	local road_left = is_road_at_pos(left_pos)
	if road_left then
		-- Turn left
		local left_dir = turn_left(dir_f)
		return nil, false, left_dir
	end
	
	-- Priority 4: Dead end - no road in any direction
	return nil, false, nil
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
		collisionbox = {-1.000, 0.000, -3.616, 1.000, 3.145, 3.145},
		selectionbox = {-1.100, 0.000, -3.931, 1.100, 3.774, 3.459},
		visual = "mesh",
		mesh = "smallbus.obj",
		textures = {"public_bus_texture.png"},
		visual_size = {x = 10.0, y = 10.0, z = 10.0},
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
				return
			end
		end

		-- Otherwise, try to attach
		for i = 1, 8 do
			if not self.passengers[i] then
				self.passengers[i] = name
				local seat = seat_offsets[i]
				-- Since the bus's visual_size is scaled 10x, the passenger is rendered
				-- at seat_offset * 10, but the passenger camera is not scaled.
				-- We shift the first-person and third-person eye offset by seat * 9
				-- (and add y=10 for the default height) to align the camera perfectly
				-- with the passenger's 10x scaled seating position.
				-- The passenger is now facing forward (0 rotation) relative to the bus.
				local eye_offset = {
					x = seat.x * 9.0,
					y = seat.y * 9.0 + 10.0,
					z = seat.z * 9.0
				}
				clicker:set_attach(self.object, "", seat, {x=0, y=0, z=0})
				clicker:set_eye_offset(eye_offset, eye_offset)
				return
			end
		end

		minetest.chat_send_player(name, "The bus is full!")
	end,

	-- ========================================================================
	-- STATE MACHINE & PATHFINDING INSIDE on_step
	-- Uses the new find_path_target function with priority rules
	-- ========================================================================
	on_step = function(self, dtime)
		local pos = self.object:get_pos()
		if not pos then return end

		-- Initialize blocks_since_turn counter for turning cooldown logic
		if not self.blocks_since_turn then
			self.blocks_since_turn = 10 -- Start high so normal driving isn't affected
		end

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
					end
				end
			end
		end

		-- Ensure dir_f is initialized
		if not self.dir_f then
			local yaw = self.object:get_yaw() or 0
			local dir = minetest.yaw_to_dir(yaw)
			if math.abs(dir.x) > math.abs(dir.z) then
				self.dir_f = {x = dir.x > 0 and 1 or -1, y = 0, z = 0}
			else
				self.dir_f = {x = 0, y = 0, z = dir.z > 0 and 1 or -1}
			end
		end

		-- Perpendicular right vector
		local dir_r = {x = self.dir_f.z, y = 0, z = -self.dir_f.x}

		-- 2. Player and Mob Detection in front of the bus (avoid pushing/colliding)
		-- Scaled for 3-block wide, ~6.8-block long bus (front is 3.65 blocks from center)
		local front_center = {
			x = pos.x + self.dir_f.x * 5.15,
			y = pos.y + 0.5,
			z = pos.z + self.dir_f.z * 5.15
		}
		local objects = minetest.get_objects_inside_radius(front_center, 2.0)
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

		-- Set/Reset Stopped States
		if obstacle_player then
			self.state = "STOPPED_FOR_PLAYER"
		elseif obstacle_mob then
			self.state = "STOPPED_FOR_MOB"
		elseif self.state == "STOPPED_FOR_PLAYER" or self.state == "STOPPED_FOR_MOB" then
			self.state = "DRIVING"
		end

		-- 3. Execute States
		-- STOPPED states: halt movement
		if self.state == "STOPPED_FOR_PLAYER" or self.state == "STOPPED_FOR_MOB" then
			local vel = self.object:get_velocity() or {x=0, y=0, z=0}
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			return
		end

		-- TURNING state: execute 90-degree turn
		if self.state == "TURNING" then
			local vel = self.object:get_velocity() or {x=0, y=0, z=0}
			self.object:set_velocity({x = 0, y = vel.y, z = 0})

			self.turn_timer = self.turn_timer + dtime
			if self.turn_timer >= 0.5 then
				self.turn_timer = 0
				-- Apply the pending turn direction
				self.dir_f = self.pending_turn_dir
				self.yaw = minetest.dir_to_yaw(self.dir_f)
				self.object:set_yaw(self.yaw)

				-- Recalculate right perpendicular vector for the new direction
				dir_r = {x = self.dir_f.z, y = 0, z = -self.dir_f.x}

				-- Enter turning cooldown: drive straight for 4 blocks without checking sides
				self.state = "DRIVING"
				self.blocks_since_turn = 0
			end
			return
		end

		-- DRIVING state: use new pathfinding logic
		if self.state == "DRIVING" then
			-- Call the new pathfinding function with priority rules
			local target_pos, should_jump, turn_dir = find_path_target(pos, self.dir_f, dir_r, self.blocks_since_turn)

			-- Handle Priority 4: Dead end (no road anywhere)
			if not target_pos and not turn_dir then
				-- Stop the bus - no valid path
				local vel = self.object:get_velocity() or {x=0, y=0, z=0}
				self.object:set_velocity({x = 0, y = vel.y, z = 0})
				return
			end

			-- Handle Priority 2 or 3: Need to turn
			if turn_dir then
				-- Initiate turn - set pending direction and switch to TURNING state
				self.pending_turn_dir = turn_dir
				self.state = "TURNING"
				self.turn_timer = 0
				local vel = self.object:get_velocity() or {x=0, y=0, z=0}
				self.object:set_velocity({x = 0, y = vel.y, z = 0})
				return
			end

			-- We have a target position - move towards it
			local vel = self.object:get_velocity() or {x=0, y=0, z=0}
			local vel_x = 0
			local vel_z = 0
			local vel_y = vel.y

			-- Increment blocks since turn counter (for cooldown logic)
			self.blocks_since_turn = self.blocks_since_turn + 1

			-- Calculate velocity based on direction of travel
			if self.dir_f.x == 0 then
				-- Moving along Z axis: align X coordinate smoothly
				local target_x = target_pos.x
				vel_x = (target_x - pos.x) * 3.0
				vel_z = self.dir_f.z * self.speed
			else
				-- Moving along X axis: align Z coordinate gently
				local target_z = target_pos.z
				vel_z = (target_z - pos.z) * 1.5
				vel_x = self.dir_f.x * self.speed
			end

			-- Handle Y movement (jumping or dropping)
			if should_jump then
				-- Jump up 1 block
				if math.abs(vel.y) < 1.0 then
					vel_y = 5.5
				end
			elseif target_pos.y < pos.y then
				-- Dropping down - let gravity handle it but ensure we're aligned
				vel_y = vel.y
			else
				-- Normal driving - stay on ground level
				-- Adjust Y velocity to settle on road level
				local y_diff = target_pos.y - pos.y
				if math.abs(y_diff) > 0.1 then
					vel_y = y_diff * 5.0
				else
					vel_y = 0
				end
			end

			self.object:set_velocity({x = vel_x, y = vel_y, z = vel_z})
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
			pos.y = pos.y + 0.1
			local ent = minetest.add_entity(pos, "public_bus:bus")
			if ent then
				local yaw = placer:get_look_horizontal()
				ent:set_yaw(yaw)
				local luaent = ent:get_luaentity()
				if luaent then
					luaent.yaw = yaw
					-- Align dir_f to closest cardinal direction
					local dir_f = minetest.yaw_to_dir(yaw)
					if math.abs(dir_f.x) > math.abs(dir_f.z) then
						luaent.dir_f = {x = dir_f.x > 0 and 1 or -1, y = 0, z = 0}
					else
						luaent.dir_f = {x = 0, y = 0, z = dir_f.z > 0 and 1 or -1}
					end
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

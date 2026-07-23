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

-- Helper: Check if a node is solid
local function is_solid(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then return true end -- treat unloaded as solid/impassable
	local def = minetest.registered_nodes[node.name]
	return def and def.walkable
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
local seat_offsets = {
	{ x = -2.2, y = 3.5, z = 8.0 },  -- Front-left (Seat 1)
	{ x = 2.2,  y = 3.5, z = 8.0 },  -- Front-right (Seat 2)
	{ x = -2.2, y = 3.5, z = 3.0 },  -- Midfront-left (Seat 3)
	{ x = 2.2,  y = 3.5, z = 3.0 },  -- Midfront-right (Seat 4)
	{ x = -2.2, y = 3.5, z = -2.0 }, -- Midback-left (Seat 5)
	{ x = 2.2,  y = 3.5, z = -2.0 }, -- Midback-right (Seat 6)
	{ x = -2.2, y = 3.5, z = -7.0 }, -- Back-left (Seat 7)
	{ x = 2.2,  y = 3.5, z = -7.0 }, -- Back-right (Seat 8)
}

-- 3. Entity Registration (public_bus:bus)
minetest.register_entity("public_bus:bus", {
	initial_properties = {
		physical = true,
		collisionbox = {-0.5, 0.0, -1.0, 0.5, 1.0, 1.15},
		selectionbox = {-0.6, 0.0, -1.1, 0.6, 1.2, 1.25},
		visual = "mesh",
		mesh = "smallbus.obj",
		textures = {"public_bus_texture.png"},
		colors = {},
		spritediv = {x=1, y=1},
		initial_sprite_basepos = {x=0, y=0},
		is_visible = true,
		makes_footstep_sound = false,
		automatic_rotate = false,
		stepheight = 1.1,
	},

	state = "DRIVING", -- Possible states: "DRIVING", "STOPPED_FOR_MOB", "STOPPED_FOR_PLAYER", "TURNING"
	passengers = {}, -- Array of player names indexed 1 to 8
	yaw = 0,
	speed = 4.0,
	turn_timer = 0,
	dir_f = nil,

	on_activate = function(self, staticdata, dtime_s)
		self.object:set_armor_groups({fleshy = 100})
		self.passengers = {}
		self.state = "DRIVING"
		self.yaw = self.object:get_yaw() or 0
		self.object:set_yaw(self.yaw)
		self.object:set_acceleration({x = 0, y = -15.0, z = 0}) -- Apply gravity
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

		-- If already attached, detach
		for seat_idx, passenger_name in pairs(self.passengers) do
			if passenger_name == name then
				puncher:set_detach()
				self.passengers[seat_idx] = nil
				puncher:set_eye_offset({x=0, y=0, z=0}, {x=0, y=0, z=0})
				return
			end
		end

		-- Otherwise, try to attach
		for i = 1, 8 do
			if not self.passengers[i] then
				self.passengers[i] = name
				puncher:set_attach(self.object, "", seat_offsets[i], {x=0, y=0, z=0})
				puncher:set_eye_offset({x=0, y=10, z=0}, {x=0, y=0, z=0})
				return
			end
		end

		minetest.chat_send_player(name, "The bus is full!")
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
				clicker:set_attach(self.object, "", seat_offsets[i], {x=0, y=0, z=0})
				clicker:set_eye_offset({x=0, y=10, z=0}, {x=0, y=0, z=0})
				return
			end
		end

		minetest.chat_send_player(name, "The bus is full!")
	end,

	-- State Machine & Pathfinding Inside on_step
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
		local front_center = {
			x = pos.x + self.dir_f.x * 1.5,
			y = pos.y + 0.5,
			z = pos.z + self.dir_f.z * 1.5
		}
		local objects = minetest.get_objects_inside_radius(front_center, 1.5)
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
		if self.state == "STOPPED_FOR_PLAYER" or self.state == "STOPPED_FOR_MOB" then
			local vel = self.object:get_velocity() or {x=0, y=0, z=0}
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			return
		end

		if self.state == "TURNING" then
			local vel = self.object:get_velocity() or {x=0, y=0, z=0}
			self.object:set_velocity({x = 0, y = vel.y, z = 0})

			self.turn_timer = self.turn_timer + dtime
			if self.turn_timer >= 0.5 then
				self.turn_timer = 0
				-- Turn left
				self.dir_f = turn_left(self.dir_f)
				self.yaw = minetest.dir_to_yaw(self.dir_f)
				self.object:set_yaw(self.yaw)

				-- Verify if the new direction has a valid road ahead
				local road_found = false
				local check_pos_f = {
					x = pos.x + self.dir_f.x * 1.0,
					y = pos.y,
					z = pos.z + self.dir_f.z * 1.0
				}
				-- Scan from rightmost (d_r = 3) to leftmost (d_r = -3)
				for d_r = 3, -3, -1 do
					for _, y_diff in ipairs({0, -1, -2}) do
						local node_pos = {
							x = math.floor(check_pos_f.x + dir_r.x * d_r + 0.5),
							y = math.floor(pos.y + y_diff + 0.5),
							z = math.floor(check_pos_f.z + dir_r.z * d_r + 0.5),
						}
						local nodename = minetest.get_node(node_pos).name
						if is_road_node(nodename) then
							local pos_above1 = {x=node_pos.x, y=node_pos.y+1, z=node_pos.z}
							local pos_above2 = {x=node_pos.x, y=node_pos.y+2, z=node_pos.z}
							if not is_solid(pos_above1) and not is_solid(pos_above2) then
								road_found = true
								break
							end
						end
					end
					if road_found then break end
				end

				if road_found then
					self.state = "DRIVING"
				end
			end
			return
		end

		if self.state == "DRIVING" then
			-- Scan 1 block ahead for road
			local check_pos_f = {
				x = pos.x + self.dir_f.x * 1.0,
				y = pos.y,
				z = pos.z + self.dir_f.z * 1.0
			}
			local target_road_pos = nil

			-- Scan from rightmost (d_r = 3) to leftmost (d_r = -3) to find the rightmost valid position
			for d_r = 3, -3, -1 do
				for _, y_diff in ipairs({0, -1, -2}) do
					local node_pos = {
						x = math.floor(check_pos_f.x + dir_r.x * d_r + 0.5),
						y = math.floor(pos.y + y_diff + 0.5),
						z = math.floor(check_pos_f.z + dir_r.z * d_r + 0.5),
					}
					local nodename = minetest.get_node(node_pos).name
					if is_road_node(nodename) then
						local pos_above1 = {x=node_pos.x, y=node_pos.y+1, z=node_pos.z}
						local pos_above2 = {x=node_pos.x, y=node_pos.y+2, z=node_pos.z}
						if not is_solid(pos_above1) and not is_solid(pos_above2) then
							target_road_pos = node_pos
							break
						end
					end
				end
				if target_road_pos then break end
			end

			if not target_road_pos then
				-- Encountered a dead end or wall; stop and start turning left
				self.state = "TURNING"
				self.turn_timer = 0
				local vel = self.object:get_velocity() or {x=0, y=0, z=0}
				self.object:set_velocity({x = 0, y = vel.y, z = 0})
				return
			end

			-- Calculate speed and alignment towards target road position
			local vel = self.object:get_velocity() or {x=0, y=0, z=0}
			local vel_x = 0
			local vel_z = 0
			local vel_y = vel.y

			if self.dir_f.x == 0 then
				-- Moving along Z axis: align X coordinate smoothly
				local target_x = target_road_pos.x
				vel_x = (target_x - pos.x) * 3.0
				vel_z = self.dir_f.z * self.speed
			else
				-- Moving along X axis: align Z coordinate smoothly
				local target_z = target_road_pos.z
				vel_z = (target_z - pos.z) * 3.0
				vel_x = self.dir_f.x * self.speed
			end

			-- Handle Elevation Climbs (Jumping exactly 1 block)
			-- If target road y-coordinate is higher than bus's current floor level
			if target_road_pos.y + 0.5 > pos.y and math.abs(vel.y) < 1.0 then
				vel_y = 5.5
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

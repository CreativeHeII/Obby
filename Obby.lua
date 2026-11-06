-- Discord: creativeheii | Roblox: Cursed_GamerX

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService") -- tags > hard paths; works if stuff gets added mid-session too
local TweenService = game:GetService("TweenService") -- door tween runs server-side so everyone sees the same open

local TAG_KILL: string = "ObbyKill"
local TAG_CHECK: string = "ObbyCheckpoint"
local TAG_STEP_A: string = "ObbyPuzzleA"
local TAG_STEP_B: string = "ObbyPuzzleB"
local TAG_STEP_C: string = "ObbyPuzzleC"
local TAG_DOOR: string = "ObbyPuzzleDoor"
local TAG_LOBBY_SPAWN: string = "ObbyLobbySpawn"

local DAMAGE_FULL: number = math.huge
local ATTRIB_CKPT: string = "ObbyCheckpointIndex"
local ATTRIB_STEP: string = "ObbyPuzzleStep"

type PuzzleRuntime = {
	stepIndex: number,
	completed: boolean,
	lastWrongAt: number, -- limbs spam Touched; dont reset 5x from one bad step
}

local puzzleByPlayer: { [Player]: PuzzleRuntime } = {} -- per-player sequence, shared door
local pendingRespawn: { [Player]: CFrame } = {} -- stash CF before the old Humanoid dies and gets replaced

local function getHumanoidFromHit(hit: BasePart): Humanoid?
	local model: Model? = hit:FindFirstAncestorOfClass("Model") -- Touched gives a part, not the character
	if not model then
		return nil
	end
	return model:FindFirstChildOfClass("Humanoid") :: Humanoid?
end

local function resetPuzzleState(plr: Player): ()
	puzzleByPlayer[plr] = {
		stepIndex = 0,
		completed = false,
		lastWrongAt = 0,
	}
	local hum: Humanoid? = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:SetAttribute(ATTRIB_STEP, 0) -- debug mirror only, table above is the real state
	end
end

local function findSpawnForCheckpoint(index: number): CFrame?
	for _, inst: Instance in CollectionService:GetTagged(TAG_CHECK) do
		if inst:IsA("BasePart") then
			local part: BasePart = inst
			local idx: number? = part:GetAttribute("OrderIndex") :: number? -- match by OrderIndex, not GetTagged order
			if idx == index then
				return part.CFrame + Vector3.new(0, 3, 0) -- keep pad rotation, just lift the root a bit
			end
		end
	end
	return nil
end

local function findLobbySpawnCFrame(): CFrame
	for _, inst: Instance in CollectionService:GetTagged(TAG_LOBBY_SPAWN) do
		if inst:IsA("BasePart") then
			local p: BasePart = inst
			return p.CFrame + Vector3.new(0, 4, 0)
		end
	end
	return CFrame.new(0, 6, 0) -- no lobby tag? origin fallback, keep that area empty in the demo
end

local function teleportRootToCFrame(char: Model, cf: CFrame): ()
	local root: BasePart? = char:WaitForChild("HumanoidRootPart", 6) :: BasePart? -- CharacterAdded can fire before HRP exists
	if not root then
		return
	end
	local hum: Humanoid? = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:ChangeState(Enum.HumanoidStateType.Physics) -- pause walk while we snap the root
	end
	root.AssemblyLinearVelocity = Vector3.zero -- wipe fall velocity so they dont yeet off the pad
	root.CFrame = cf
	if hum then
		hum:ChangeState(Enum.HumanoidStateType.Running)
	end
end

local function applyCheckpoint(plr: Player, pad: BasePart): ()
	local hum: Humanoid? = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local order: number? = pad:GetAttribute("OrderIndex") :: number?
	local idx: number = if typeof(order) == "number" then order else 0
	hum:SetAttribute(ATTRIB_CKPT, idx) -- lives on this Humanoid so Died can still read it
end

local function killCharacterFromPart(hit: BasePart): ()
	local hum: Humanoid? = getHumanoidFromHit(hit)
	if not hum or hum.Health <= 0 then
		return
	end
	hum:TakeDamage(DAMAGE_FULL) -- server kill; ForceField still blocks this
end

local function flashWrongPlate(plate: BasePart): ()
	local original: Color3 = plate.Color
	plate.Color = Color3.fromRGB(255, 80, 80)
	task.delay(0.12, function() -- dont yield the touch handler just for a colour flash
		if plate.Parent then
			plate.Color = original
		end
	end)
end

local function openPuzzleDoor(): ()
	for _, inst: Instance in CollectionService:GetTagged(TAG_DOOR) do
		if inst:IsA("BasePart") then
			local door: BasePart = inst
			local goal: Vector3 = door.Position + door.CFrame.LookVector * 10 -- slide along the door's facing, not world +Z
			local info: TweenInfo = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local tween: Tween = TweenService:Create(door, info, { Position = goal, Transparency = 1 })
			tween:Play()
			tween.Completed:Wait() -- keep collision until the panel finishes so nobody clips mid-tween
			door.CanCollide = false
			return -- one door for this demo
		end
	end
end

local function puzzleTagOrder(tag: string): number?
	if tag == TAG_STEP_A then
		return 1
	elseif tag == TAG_STEP_B then
		return 2
	elseif tag == TAG_STEP_C then
		return 3
	end
	return nil
end

local function onPuzzleTouch(plr: Player, tag: string): ()
	local state: PuzzleRuntime? = puzzleByPlayer[plr]
	if not state or state.completed then
		return
	end
	local expected: number = state.stepIndex + 1 -- stepIndex = how many accepted so far
	local matched: boolean = (expected == 1 and tag == TAG_STEP_A)
		or (expected == 2 and tag == TAG_STEP_B)
		or (expected == 3 and tag == TAG_STEP_C)
	if matched then
		state.stepIndex += 1
		local hum: Humanoid? = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			hum:SetAttribute(ATTRIB_STEP, state.stepIndex)
		end
		if state.stepIndex >= 3 then
			state.completed = true
			task.spawn(openPuzzleDoor) -- openPuzzleDoor yields on Completed:Wait
		end
	else
		local orderNum: number? = puzzleTagOrder(tag)
		if orderNum and orderNum <= state.stepIndex then
			return
		end
		local nowClock: number = os.clock()
		if nowClock - state.lastWrongAt < 0.25 then -- wrong-input throttle, not a plate debounce
			return
		end
		state.lastWrongAt = nowClock
		state.stepIndex = 0
		local hum: Humanoid? = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			hum:SetAttribute(ATTRIB_STEP, 0)
		end
		for _, inst: Instance in CollectionService:GetTagged(TAG_STEP_A) do -- flash A so they know to restart there
			if inst:IsA("BasePart") then
				flashWrongPlate(inst :: BasePart)
				break
			end
		end
	end
end

local function bindKillPart(part: BasePart): ()
	local conn: RBXScriptConnection = part.Touched:Connect(function(hit: BasePart)
		if not hit or not hit.Parent then
			return
		end
		killCharacterFromPart(hit)
	end)
	part.Destroying:Connect(function() -- drop the touch conn when the part goes
		conn:Disconnect()
	end)
end

local function bindCheckpoint(pad: BasePart): ()
	local conn: RBXScriptConnection = pad.Touched:Connect(function(hit: BasePart)
		local hum: Humanoid? = getHumanoidFromHit(hit)
		if not hum then
			return
		end
		local plr: Player? = Players:GetPlayerFromCharacter(hum.Parent)
		if not plr then
			return
		end
		applyCheckpoint(plr, pad)
	end)
	pad.Destroying:Connect(function()
		conn:Disconnect()
	end)
end

local function bindPuzzlePlate(part: BasePart, tag: string): ()
	local conn: RBXScriptConnection = part.Touched:Connect(function(hit: BasePart)
		local hum: Humanoid? = getHumanoidFromHit(hit)
		if not hum then
			return
		end
		local plr: Player? = Players:GetPlayerFromCharacter(hum.Parent)
		if not plr then
			return
		end
		onPuzzleTouch(plr, tag)
	end)
	part.Destroying:Connect(function()
		conn:Disconnect()
	end)
end

local function wireExistingWorld(): ()
	local function hookTagged(base: BasePart, tag: string): () -- same map for cold start + later tags
		if tag == TAG_KILL then
			bindKillPart(base)
		elseif tag == TAG_CHECK then
			bindCheckpoint(base)
		elseif tag == TAG_STEP_A or tag == TAG_STEP_B or tag == TAG_STEP_C then
			bindPuzzlePlate(base, tag)
		end
	end

	for _, inst: Instance in CollectionService:GetTagged(TAG_KILL) do
		if inst:IsA("BasePart") then
			hookTagged(inst :: BasePart, TAG_KILL)
		end
	end
	for _, inst: Instance in CollectionService:GetTagged(TAG_CHECK) do
		if inst:IsA("BasePart") then
			hookTagged(inst :: BasePart, TAG_CHECK)
		end
	end
	for _, tagName: string in { TAG_STEP_A, TAG_STEP_B, TAG_STEP_C } do
		for _, inst: Instance in CollectionService:GetTagged(tagName) do
			if inst:IsA("BasePart") then
				hookTagged(inst :: BasePart, tagName)
			end
		end
	end

	CollectionService:GetInstanceAddedSignal(TAG_KILL):Connect(function(inst: Instance) -- also catch parts tagged after Script start
		if inst:IsA("BasePart") then
			bindKillPart(inst :: BasePart)
		end
	end)
	CollectionService:GetInstanceAddedSignal(TAG_CHECK):Connect(function(inst: Instance)
		if inst:IsA("BasePart") then
			bindCheckpoint(inst :: BasePart)
		end
	end)
	for _, tagName: string in { TAG_STEP_A, TAG_STEP_B, TAG_STEP_C } do
		CollectionService:GetInstanceAddedSignal(tagName):Connect(function(inst: Instance)
			if inst:IsA("BasePart") then
				bindPuzzlePlate(inst :: BasePart, tagName)
			end
		end)
	end
end

local function computeRespawnCFrame(plr: Player): CFrame
	local char: Model? = plr.Character
	if not char then
		return findLobbySpawnCFrame()
	end
	local hum: Humanoid? = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return findLobbySpawnCFrame()
	end
	local ck: number? = hum:GetAttribute(ATTRIB_CKPT) :: number?
	local cfPad: CFrame? = if typeof(ck) == "number" then findSpawnForCheckpoint(ck) else nil -- resolve at death; missing pad -> lobby
	if cfPad then
		return cfPad
	end
	return findLobbySpawnCFrame()
end

local function onCharacterAdded(plr: Player, char: Model): ()
	local pending: CFrame? = pendingRespawn[plr]
	if pending then
		local target: CFrame = pending
		pendingRespawn[plr] = nil -- one-shot, dont reuse for a later spawn
		task.defer(function() -- out of the spawn callback; WaitForChild inside handles late HRP
			teleportRootToCFrame(char, target)
		end)
	end
	resetPuzzleState(plr)
	local hum: Humanoid? = char:WaitForChild("Humanoid", 6) :: Humanoid?
	if not hum then
		return
	end
	hum.Died:Once(function() -- grab checkpoint off the dying Humanoid before its gone
		pendingRespawn[plr] = computeRespawnCFrame(plr)
	end)
end

local function onPlayerAdded(plr: Player): ()
	resetPuzzleState(plr)
	plr.CharacterAdded:Connect(function(char: Model)
		onCharacterAdded(plr, char)
	end)
	if plr.Character then -- Studio / late Script start: character may already be here
		onCharacterAdded(plr, plr.Character)
	end
end

wireExistingWorld()
Players.PlayerAdded:Connect(onPlayerAdded)

for _, plr: Player in Players:GetPlayers() do -- PlayerAdded misses people already in the server
	onPlayerAdded(plr)
end

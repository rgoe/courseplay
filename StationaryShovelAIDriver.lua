---WIP needs more improvements

StationaryShovelAIDriver = CpObject(AIDriver)

StationaryShovelAIDriver.myStates = {
	CHECK_SILO_AND_PRE_PIPE_POSITION = {},
	SEARCHING_FOR_UNLOADERS = {},
	HAS_AIDRIVER_UNLOADER = {},
	UNLOADING = {}
}

StationaryShovelAIDriver.PRE_TARGET_UNLOADING_POSITION_OFFSET = 10

function StationaryShovelAIDriver:init(vehicle)
	AIDriver.init(self,vehicle)
	self:initStates(StationaryShovelAIDriver.myStates)
	self.dischargeNode = self.vehicle:getCurrentDischargeNode()
	self.unloaderState = self.states.CHECK_SILO_AND_PRE_PIPE_POSITION
	self.debugChannel = 10
	self:createDischargeNodeTrigger()
end

function StationaryShovelAIDriver:setHudContent()
	AIDriver.setHudContent(self)
	courseplay.hud:setStationaryShovelAIDriverContent(self.vehicle)
end

---ugly hack so we can use the pipe trigger, that's not already initialized
function StationaryShovelAIDriver:createDischargeNodeTrigger()
	if self.dischargeNodeTrigger == nil then
		local xmlFile = self.vehicle.xmlFile
		self.dischargeNodeTrigger = {}
		local key = "vehicle.pipe.unloadingTriggers.unloadingTrigger(0)#node"
		self.dischargeNodeTrigger.node = I3DUtil.indexToObject(self.vehicle.components, getXMLString(xmlFile, key), self.vehicle.i3dMappings)
		self.dischargeNodeTrigger.numObjects = 0 
		self.dischargeNodeTrigger.objects = {} 
		if self.vehicle.isAddedToPhysics then --another ugly hack to make sure on trigger creation we do a trigger check
			self.vehicle:removeFromPhysics()
			if self.dischargeNodeTrigger.node ~= nil then
				addTrigger(self.dischargeNodeTrigger.node, "dischargeNodeTriggerCallback", self)
				setCollisionMask(self.dischargeNodeTrigger.node,1073741824) --same as trailerTrigger from spec_pipe
			end
			self.vehicle:addToPhysics()
		else 
			if self.dischargeNodeTrigger.node ~= nil then
				addTrigger(self.dischargeNodeTrigger.node, "dischargeNodeTriggerCallback", self)
				setCollisionMask(self.dischargeNodeTrigger.node,1073741824) --same as trailerTrigger from spec_pipe
			end
		end
	end
end

function StationaryShovelAIDriver:start(startingPoint)	
	self:beforeStart()
	self.unloaderState = self.states.CHECK_SILO_AND_PRE_PIPE_POSITION
	self.targetVehicle = nil
	self.bunkerSiloManager = nil
	self.bestTarget = nil
	self.preTargetUnloadPosition = nil
	self.initConveyorsDone = nil
	--left or right of the vehicle 
	self.preTargetUnloadSide = self.vehicle.cp.settings.unloadLeftOrRight:get()
	--override giants values to enable automation and store them in a variable to reset them later
	
	if self.vehicle:getCanBeTurnedOn() then
		self.vehicle:setIsTurnedOn(true)
	end
	self.vehicle:aiImplementStartLine()
	self.vehicle:raiseStateChange(Vehicle.STATE_CHANGE_AI_START_LINE)
	
	self.oldCanDischargeToGround = self.dischargeNode.canDischargeToGround
	self.oldCanStartDischargeAutomatically = self.dischargeNode.canStartDischargeAutomatically
	self.dischargeNode.canDischargeToGround = false
	self.dischargeNode.canStartDischargeAutomatically = true
	AIDriver.start(self,startingPoint)
end

function StationaryShovelAIDriver:stop(stopMsg)
	-- reset old giants variable
	self.dischargeNode.canDischargeToGround = self.oldCanDischargeToGround
	self.dischargeNode.canStartDischargeAutomatically = self.oldCanStartDischargeAutomatically
	AIDriver.stop(self,stopMsg)
end

function StationaryShovelAIDriver:drive(dt)
	self:checkTargetVehicle()
	--search for a heap and set pre conveyor position
	if self.unloaderState == self.states.CHECK_SILO_AND_PRE_PIPE_POSITION then 
		if self:checkSilo() then--and self:prePipePositionReached(dt) then 
			self.unloaderState = self.states.SEARCHING_FOR_UNLOADERS
		end
	--searching for GrainTransportAIDriver or check the trigger for trailers
	elseif self.unloaderState == self.states.SEARCHING_FOR_UNLOADERS then 
		if self.dischargeNodeTrigger.numObjects > 0 then 
			self.unloaderState = self.states.UNLOADING
		else 
			--we haven't found a GrainTransportAIDriver, so search for one
			if self.targetVehicle == nil then
				if  g_updateLoopIndex % 100 == 0  then
					if self:foundUnloaderInRadius(1000) then 
						self.unloaderState = self.states.HAS_AIDRIVER_UNLOADER
					end
				end
			else
				self.unloaderState = self.states.HAS_AIDRIVER_UNLOADER
			end
		end
	--waiting for driver to arrive 
	elseif self.unloaderState == self.states.HAS_AIDRIVER_UNLOADER then
		if self.dischargeNodeTrigger.numObjects > 0 then 
			self.unloaderState = self.states.UNLOADING
		end
	--handle the conveyors and driving through the heap
	elseif self.unloaderState == self.states.UNLOADING then
		local targetUnit = self.bunkerSiloManager.siloMap[self.bestTarget.line][self.bestTarget.column]
		local gx,_,gz = worldToLocal(AIDriverUtil.getDirectionNode(self.vehicle),targetUnit.bx,_,targetUnit.bz)
		self:driveVehicleToLocalPosition(dt, self:isAllowedToMove(), true, gx, gz, self:getNeededSpeed())
		if self.dischargeNodeTrigger.numObjects == 0 then 
			self.unloaderState = self.states.SEARCHING_FOR_UNLOADERS
		end
	end
	self:drawMap()
end

function StationaryShovelAIDriver:isAlignmentCourseNeeded(ix)
	-- never use alignment course for grain transport mode
	return false
end

function StationaryShovelAIDriver:drawMap()
	if self:isDebugActive() and self.bunkerSiloManager then
		self.bunkerSiloManager:drawMap()
		self.bunkerSiloManager:debugRouting(self.bestTarget)
	end
end

function StationaryShovelAIDriver:isDebugActive() 
	return courseplay.debugChannels[10]
end

---get a heap map directly in front 
---@return boolean valid silo found
function StationaryShovelAIDriver:checkSilo()
	if self.bunkerSiloManager == nil then
		local silo = BunkerSiloManagerUtil.getHeapCoordsByStartNode(self.vehicle,self.vehicle.rootNode,200)
		if silo then 
			self:debugSparse("silo found")
			self.bunkerSiloManager = BunkerSiloManager(self.vehicle,silo,self:getWorkWidth(),self:getFrontMarkerNode(self.vehicle),true)
			-- BunkerSiloManager:init(vehicle, Silo, width, object,isHeap)
			self.bestTarget = {
				line = #self.bunkerSiloManager.siloMap[1],
				column = 1
			}
		end
	end
	if not self.bunkerSiloManager then
		courseplay:setInfoText(self.vehicle, courseplay:loc('COURSEPLAY_MODE10_NOSILO'));
	else
		return true
	end
end

---set pre position either to the left or right, to have the dischargeNodeTrigger at the right position 
---@return boolean reached pre position
function StationaryShovelAIDriver:prePipePositionReached(dt)
	if self:hasOuterArmHeightMovedUpCompletely(dt) then
		if self.initConveyorsDone == nil then 
			self:initConveyors()
			self.initConveyorsDone = true
		end
		if self.preTargetUnloadPosition == nil then
			local xOffset = 0
			if self.preTargetUnloadSide == UnloadLeftOrRightSetting.LEFT then 
				xOffset = self.PRE_TARGET_UNLOADING_POSITION_OFFSET
			else 
				xOffset = -self.PRE_TARGET_UNLOADING_POSITION_OFFSET
			end	
			self.preTargetUnloadPosition = courseplay.createNode( 'preTargetUnloadPosition',0,0,0,self.vehicle.rootNode) 
			setTranslation(self.preTargetUnloadPosition , xOffset, 0, -2)
		else 
			DebugUtil.drawDebugNode(self.preTargetUnloadPosition, "preTargetUnloadPosition", true)
			local moving = true
			self:updateConveyorsGoalPoints(dt,self.preTargetUnloadPosition)
			moving = self:updateConveyors(dt,self.preTargetUnloadPosition)
			return not moving
		end
	end
	return false
end

---get the goal position of the conveyor 
---@return exactFillRootNode of the first trailer
function StationaryShovelAIDriver:getFirstValidExactFillRootNode()
	if self.dischargeNodeTrigger.numObjects > 0 then 
		for object, data in pairs(self.dischargeNodeTrigger.objects) do
			local exactFillRootNode = data.exactFillRootNode
			if exactFillRootNode then 
				return exactFillRootNode
			end
		end
	end
end

--update the heap goal point for driving
function StationaryShovelAIDriver:updateTarget()
	self.bunkerSiloManager:updateTarget(self.bestTarget)
end

--check the if target GrainTransportAIDriver is still valid or for example full is
function StationaryShovelAIDriver:checkTargetVehicle()
	if self.targetVehicle then 
		if not self.targetVehicle.cp.driver:isActive() or self.targetVehicle.cp.driver.readyToLoadManualAtStart == nil then 
			self.targetVehicle = nil
			self.unloaderState = self.states.SEARCHING_FOR_UNLOADERS
		end
	end
end

function StationaryShovelAIDriver:getNeededSpeed()
	if self:isAllowedToMove() then
		return 1
	end
	return 0
end

---have we cleared everything in front and can continue moving
---@return boolean isAllowedToMove
function StationaryShovelAIDriver:isAllowedToMove()
	local spec = self.vehicle.spec_shovel
	if self.vehicle:getFillUnitFillLevelPercentage(1) < 0.02 and spec.loadingFillType == FillType.UNKNOWN then
		if self.targetVehicle then
			self.targetVehicle.cp.driver:updateTemporaryGoalNode()
		end
		return true
	end
	return false
end

---search for closest GrainTransportAIDriver in radius r
---@return boolean found driver
function StationaryShovelAIDriver:foundUnloaderInRadius(r)
	if g_currentMission then
		local closestVehicle = nil
		local closestDistance = r
		for _, vehicle in pairs(g_currentMission.vehicles) do
			if vehicle ~= self.vehicle then
				if courseplay:isAIDriverActive(vehicle) and vehicle.cp.driver.readyToLoadManualAtStart then 
					local d = calcDistanceFrom(self.vehicle.rootNode, vehicle.rootNode)
					if d < closestDistance then 
						closestDistance = d
						closestVehicle = vehicle
					end
				end
			end
		end
		if closestVehicle then 
			closestVehicle.cp.driver:setTemporaryGoalNode(self.dischargeNode.node,self.vehicle)
			self.targetVehicle = closestVehicle
			return true
		end
	end
end

function StationaryShovelAIDriver:getWorkWidth()
	return self.vehicle.cp.workWidth
end

--debug info
function StationaryShovelAIDriver:onDraw()
	if self:isDebugActive() then 
		local y = 0.5
		y = self:renderText(y,"unloaderState: "..tostring(self.unloaderState.name),0.4)
		y = self:renderText(y,"hasBunkerSiloManager: "..tostring(self.bunkerSiloManager ~= nil),0.4)
		y = self:renderText(y,"hasTargetVehicle: "..tostring(self.targetVehicle ~= nil),0.4)
		y = self:renderText(y,"hasTargetVehicle: "..tostring(self.targetVehicle ~= nil),0.4)
		local fillTypeIndex = self.vehicle.spec_shovel.loadingFillType
		y = self:renderText(y,"fillType: "..tostring(g_fillTypeManager.fillTypes[fillTypeIndex].name),0.4)
		y = self:renderText(y,string.format("fillLevel: %.2f",self.vehicle:getFillUnitFillLevelPercentage(1)),0.4)
		y = self:debugDischargeNodeTrigger(y,0.4)
	end
	AIDriver.onDraw(self)
end

function StationaryShovelAIDriver:debugDischargeNodeTrigger(y,xOffset)
	if self.dischargeNodeTrigger then 
		y = self:renderText(y,"dischargeNodeTrigger.numObjects: "..self.dischargeNodeTrigger.numObjects,xOffset)
		for object, data in pairs(self.dischargeNodeTrigger.objects) do 
			y = self:renderText(y,"object: "..nameNum(object),xOffset)
			y = self:renderText(y,"objectFillUnitIndex: "..data.fillUnitIndex,xOffset)
		end
	end	
	return y
end

function StationaryShovelAIDriver:renderText(y,text,xOffset)
	renderText(xOffset and 0.3+xOffset or 0.3,y,0.02,tostring(text))
	return y-0.02
end

function StationaryShovelAIDriver:isTrafficConflictDetectionEnabled()
	return false
end

function StationaryShovelAIDriver:isProximitySwerveEnabled()
	return false
end

function StationaryShovelAIDriver:isProximitySpeedControlEnabled()
	return false
end

function StationaryShovelAIDriver:delete()
	AIDriver.delete(self)
	if self.preTargetUnloadPosition then 
		courseplay.destroyNode( self.preTargetUnloadPosition )
	end
	if self.dischargeNodeTrigger.node ~= nil then
		removeTrigger(self.dischargeNodeTrigger.node)
	end
	self:resetMovingTools()
end

function StationaryShovelAIDriver:dischargeNodeTriggerCallback(triggerId, otherActorId, onEnter, onLeave, onStay, otherShapeId)
	if onEnter or onLeave then
		local object = g_currentMission:getNodeObject(otherActorId)
        if object ~= nil and object ~= self and object:isa(Vehicle) then
            if object.getFillUnitIndexFromNode ~= nil then
				local fillUnitIndex = object:getFillUnitIndexFromNode(otherActorId)
				local dischargeNode = self.dischargeNode
				if dischargeNode ~= nil and fillUnitIndex ~= nil then
					self:debug("dischargeNodeTriggerCallback(%s): valid object found: %s",onEnter and "onEnter" or "onLeave",nameNum(object))
                    local trigger = self.dischargeNodeTrigger
                    if onEnter then
                        if trigger.objects[object] == nil then
                            trigger.objects[object] = {count=0, fillUnitIndex=fillUnitIndex, exactFillRootNode = otherActorId, shape=otherShapeId}
                            trigger.numObjects = trigger.numObjects + 1
                            object:addDeleteListener(self, "onDeleteDischargeNodeTriggerObject")
                        end
                        trigger.objects[object].count = trigger.objects[object].count + 1
                    elseif onLeave then
						if trigger.objects[object] then
							trigger.objects[object].count = trigger.objects[object].count - 1
							if trigger.objects[object].count == 0 then
								trigger.objects[object] = nil
								trigger.numObjects = trigger.numObjects - 1
								object:removeDeleteListener(self, "onDeleteDischargeNodeTriggerObject")
							end
						end
                    end
                end
			end
		end
	else 
		self:debug("dischargeNodeTriggerCallback no onEnter or onLeave")
	end
end

function StationaryShovelAIDriver:onDeleteDischargeNodeTriggerObject(object)
	local trigger = self.dischargeNodeTrigger
	if trigger.objects[object] ~= nil then
		trigger.objects[object] = nil
		trigger.numObjects = trigger.numObjects - 1
		self:debug("deleted object found: %s",nameNum(object))
	end
end

StationaryShovelAIDriver.Conveyors = {}
StationaryShovelAIDriver.Conveyors.Base_Arm = {}
StationaryShovelAIDriver.Conveyors.Base_Arm.toolIndex = 1
StationaryShovelAIDriver.Conveyors.Outer_Arm = {}
StationaryShovelAIDriver.Conveyors.Outer_Arm.toolIndex = 2
StationaryShovelAIDriver.Conveyors.Outer_Arm_Height = {}
StationaryShovelAIDriver.Conveyors.Outer_Arm_Height.toolIndex = 3

function StationaryShovelAIDriver:initConveyors()		
	local spec = self.vehicle.spec_cylindered
	local baseArmTool = spec.movingTools[self.Conveyors.Base_Arm.toolIndex]
	local outerArmTool = spec.movingTools[self.Conveyors.Outer_Arm.toolIndex]
	local outerArmHeightTool = spec.movingTools[self.Conveyors.Outer_Arm_Height.toolIndex]

	local x1,_,z1 = localToLocal(outerArmTool.node, baseArmTool.node, 0, 0, 0)
	local baseArmLength = math.sqrt(x1^2+z1^2)+1
	local x2,_,z2 = localToLocal(self.dischargeNode.node, outerArmTool.node, 0, 0, 0)
	local outerArmLength = math.sqrt(x2^2+z2^2)+1
	local totalLength = baseArmLength+outerArmLength
	self.conveyors = {}
	self.conveyors.baseArmLength = baseArmLength
	self.conveyors.outerArmLength = outerArmLength
	self.conveyors.totalLength = totalLength
	self.conveyors.baseArmDelta = baseArmLength/totalLength
	self.conveyors.outerArmDelta = outerArmLength/totalLength
end

--force stops the movements of the conveyors 
function StationaryShovelAIDriver:resetMovingTools()
	self:resetConveyors()
end

function StationaryShovelAIDriver:hasOuterArmHeightMovedUpCompletely(dt)
	local spec = self.vehicle.spec_cylindered
	local tool = spec.movingTools[self.Conveyors.Outer_Arm_Height.toolIndex]
	local curRot = { getRotation(tool.node) }
	local newRot = curRot[tool.rotationAxis]
	if tool == nil or tool.rotSpeed == nil then
		return
	end
	local rotSpeed =0.3
	if math.abs(newRot - tool.rotMin) > 0.003 then
		tool.move = -rotSpeed
		if tool.move ~= tool.moveToSend then
			tool.moveToSend = tool.move
			self.vehicle:raiseDirtyFlags(spec.cylinderedInputDirtyFlag)
		end
		return false
	end
	tool.move = 0
	return true
end

function StationaryShovelAIDriver:updateConveyorsGoalPoints(dt,targetPosition)
	local spec = self.vehicle.spec_cylindered
	local baseArmTool = spec.movingTools[self.Conveyors.Base_Arm.toolIndex]
	local outerArmTool = spec.movingTools[self.Conveyors.Outer_Arm.toolIndex]
	local outerArmHeightTool = spec.movingTools[self.Conveyors.Outer_Arm_Height.toolIndex]
	local curRotBaseArmTool = { getRotation(baseArmTool.node) }
	local newRotBaseArmTool = curRotBaseArmTool[baseArmTool.rotationAxis]
	local curRotOuterArmTool = { getRotation(outerArmTool.node) }
	local newRotOuterArmTool = curRotOuterArmTool[outerArmTool.rotationAxis]
	--coordinates between first toolNode and targetPosition
	local x,_,z = localToLocal(targetPosition, baseArmTool.node, 0, 0, 0)
	local ix,_,iz = localDirectionToLocal(targetPosition, self.vehicle.rootNode, 0, 0, 1)
	--local ix,_,iz = localToLocal(targetPosition, self.vehicle.rootNode, 0, 0, 0)
	
	local delta = -math.atan2(ix,iz)
	
	local ix,_,iz = localDirectionToLocal(targetPosition, outerArmTool.node, 0, 0, 0)
	
	local delta2 = math.atan2(ix,iz)
	local baseArmLength = self.conveyors.baseArmLength
	local outerArmLength = self.conveyors.outerArmLength
	local baseArmDelta = self.conveyors.baseArmDelta
	local outerArmDelta = self.conveyors.outerArmDelta
	
	local c = math.sqrt(x^2+z^2)
	local a = c*baseArmDelta
	local b = c*outerArmDelta 
	local h = math.sqrt(baseArmLength^2-a^2)
	print(string.format("x= %.2f, z= %.2f",x,z))
	print(string.format("baseArmLength= %.2f,outerArmLength= %.2f,baseArmDelta= %.2f,outerArmDelta= %.2f",baseArmLength,outerArmLength,baseArmDelta,outerArmDelta))
	print(string.format("c= %.2f,a= %.2f,b= %.2f,h= %.2f",c,a,b,h))
	local alpha1 = math.acos(a/baseArmLength)
	local beta1 = math.asin(h/baseArmLength)
	local alpha2 = math.acos(b/outerArmLength)
	local beta2 = math.asin(h/outerArmLength)
	print(string.format("alpha1= %.2f, alpha2= %.2f",alpha1,alpha2))
	print(string.format("beta1= %.2f, beta2= %.2f",beta1,beta2))
	local gamma = math.pi-beta1-beta2
	print(string.format("gamma= %.2f, delta1= %.2f, delta2= %.2f",gamma,delta,delta2))
	self.goalAngles = {}
	self.goalAngles[1] = {}
	self.goalAngles[1].alpha = alpha1--newRotBaseArmTool+alpha1
	self.goalAngles[1].gamma = -gamma--+newRotBaseArmTool--+1.25
	self.goalAngles[2] = {}
	self.goalAngles[2].alpha = -alpha1--newRotBaseArmTool-alpha2
	self.goalAngles[2].gamma = gamma--+newRotBaseArmTool--+1.25

--	print(string.format("delta= %.2f, alpha= %.2f,alpha1= %.2f, gamma= %.2f",delta,self.goalAngles[1].alpha,alpha1,self.goalAngles[1].gamma))
--	print(string.format("delta2= %.2f, alpha= %.2f,alpha2= %.2f, gamma= %.2f",delta2,self.goalAngles[2].alpha,alpha2,self.goalAngles[2].gamma))
	print(string.format("curRotBaseArmTool= %.2f, curRotOuterArmTool= %.2f",newRotBaseArmTool,newRotOuterArmTool))
	print(string.format("curRotBaseArmToolMin= %.2f, curRotOuterArmToolMin= %.2f",baseArmTool.rotMin,outerArmTool.rotMin))
	print(string.format("curRotBaseArmToolMax= %.2f, curRotOuterArmToolMax= %.2f",baseArmTool.rotMax,outerArmTool.rotMax))
end

function StationaryShovelAIDriver:updateConveyors(dt,targetPosition)
	local spec = self.vehicle.spec_cylindered
	local baseArmTool = spec.movingTools[self.Conveyors.Base_Arm.toolIndex]
	local outerArmTool = spec.movingTools[self.Conveyors.Outer_Arm.toolIndex]
	local curRotBaseArmTool = { getRotation(baseArmTool.node) }
	local newRotBaseArmTool = curRotBaseArmTool[baseArmTool.rotationAxis]
	local curRotOuterArmTool = { getRotation(outerArmTool.node) }
	local newRotOuterArmTool = curRotOuterArmTool[outerArmTool.rotationAxis]
	local isLeft = false
	if self.preTargetUnloadSide == UnloadLeftOrRightSetting.LEFT then 
		isLeft = true
	end
	local hasBaseArmMoved = false
	local hasOuterArmMoved = false
	if self:areRotationBoundsValid(baseArmTool,self.goalAngles[1].alpha) and self:areRotationBoundsValid(outerArmTool,self.goalAngles[1].gamma) then 
		if not self:isMoveToolNearTargetRot(baseArmTool,self.goalAngles[1].alpha) then 
			local dir = self:getNeededMoveToolDirection(baseArmTool,self.goalAngles[1].alpha)
			baseArmTool.move = 0.1 * dir
			hasBaseArmMoved = true
		else 
			baseArmTool.move = 0
		end
		if not self:isMoveToolNearTargetRot(outerArmTool,self.goalAngles[1].gamma) then 
			local dir = self:getNeededMoveToolDirection(outerArmTool,self.goalAngles[1].gamma)
			outerArmTool.move = 0.1 * dir
			hasOuterArmMoved = true
		else 
			outerArmTool.move = 0
		end
	elseif self:areRotationBoundsValid(baseArmTool,self.goalAngles[2].alpha) and self:areRotationBoundsValid(outerArmTool,self.goalAngles[2].gamma) then 
		if not self:isMoveToolNearTargetRot(baseArmTool,self.goalAngles[2].alpha) then 
			local dir = self:getNeededMoveToolDirection(baseArmTool,self.goalAngles[2].alpha)
			baseArmTool.move = 0.1 * dir
			hasBaseArmMoved = true
		else 
			baseArmTool.move = 0
		end
		if not self:isMoveToolNearTargetRot(outerArmTool,self.goalAngles[2].gamma) then 
			local dir = self:getNeededMoveToolDirection(outerArmTool,self.goalAngles[2].gamma)
			outerArmTool.move = 0.1 * dir
			hasOuterArmMoved = true
		else 
			outerArmTool.move = 0
		end
	else 
		outerArmTool.move = 0
		baseArmTool.move = 0
	end
	if baseArmTool.move ~= baseArmTool.moveToSend then
		baseArmTool.moveToSend = baseArmTool.move
		self.vehicle:raiseDirtyFlags(spec.cylinderedInputDirtyFlag)
	end
	if outerArmTool.move ~= outerArmTool.moveToSend then
		outerArmTool.moveToSend = outerArmTool.move
		self.vehicle:raiseDirtyFlags(spec.cylinderedInputDirtyFlag)
	end

	--print(string.format("movingTool(%d), diffRotMax= %.3f, diffRotMin= %.3f, rotSpeed= %.2f",toolIndex,diffRotMax,diffRotMin,rotSpeed))
--	print(string.format("tool(%d): angle= %.2f,curRot= %.2f, angleDiff= %.2f",self.Conveyors.Base_Arm.toolIndex,angleBaseArm,newRotBaseArmTool,self.conveyorsGoalPoints.baseArmToolRotation))
--	print(string.format("tool(%d): angle= %.2f,curRot= %.2f, angleDiff= %.2f",self.Conveyors.Outer_Arm.toolIndex,angleOuterArm,newRotOuterArmTool,self.conveyorsGoalPoints.outerArmToolRotation))
	print("hasBaseArmMoved: "..tostring(hasBaseArmMoved)..", hasOuterArmMoved: "..tostring(hasOuterArmMoved))
	return true--hasOuterArmMoved or hasBaseArmMoved
end

function StationaryShovelAIDriver:areRotationBoundsValid(tool,targetRot)
	if targetRot < tool.rotMax and targetRot > tool.rotMin then 
		return true
	end
	return false
end

function StationaryShovelAIDriver:getNeededMoveToolDirection(tool,targetRot)
	local curRot = { getRotation(tool.node) }
	local newRot = curRot[tool.rotationAxis]
	local dir = MathUtil.sign(targetRot-newRot)
	return dir
end

function StationaryShovelAIDriver:isMoveToolNearTargetRot(tool,targetRot)
	local curRot = { getRotation(tool.node) }
	local newRot = curRot[tool.rotationAxis]
	if math.abs(newRot-targetRot) < 0.05 then 
		return true
	end
	return false
end

function StationaryShovelAIDriver:resetConveyors()
	local spec = self.vehicle.spec_cylindered
	local baseArmTool = spec.movingTools[self.Conveyors.Base_Arm.toolIndex]
	local outerArmTool = spec.movingTools[self.Conveyors.Outer_Arm.toolIndex]
	local outerArmHeightTool = spec.movingTools[self.Conveyors.Outer_Arm_Height.toolIndex]
	baseArmTool.move = 0
	outerArmTool.move = 0
	outerArmHeightTool.move = 0
end


--move conveyors to the nextClosestExactFillRootNode
function StationaryShovelAIDriver:updateConveyor(target,dt)
	if target then
		DebugUtil.drawDebugNode(target,"targetExactFillRootNode",false)
		self:updateConveyorsGoalPoints(dt,target)
		self:updateConveyors(dt,target)
	else 
		self:resetMovingTools()
	end
end
/**
 Copyright (C) 2012-2019 by Autodesk, Inc.
 All rights reserved.

 Custom CrossFire Gen2 Plasma post processor configuration for FireControl
 $Revision: v1.0 $
 Modified by Carter Spangler
 $Date: 2026-04-21 18:01:05 $
 FORKID {C59C057C-1427-4281-AE93-4F04BBA3F45E}
 */

description = "FireControl Plasma v1.6 (Enhanced)";
vendor = "Langmuir Systems";
vendorUrl = "http://www.langmuirsystems.com";
legal = "Copyright (C) 2012-2019 by Autodesk, Inc.";
certificationLevel = 2;
minimumRevision = 24000;
highFeedrate = (unit == IN) ? 100 : 2500;

longDescription = "Post Processor for Langmuir Systems FireControl for CrossFire Gen2 Plasma CNC with advanced features.";

extension = "nc";
setCodePage("ascii");

capabilities = CAPABILITY_JET | CAPABILITY_MACHINE_SIMULATION;
tolerance = spatial(0.002, MM);

minimumChordLength = spatial(0.25, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = false;
allowedCircularPlanes = 1 << PLANE_XY; // only XY

var maxCuttingFeedRate = 0;
var firstLoop = true;
var pierceCount = 0;
var reHomeThreshold = 10; // Re-home Z-axis after every 10 pierces

// statically-defined properties
staticproperties = {
    writeMachine: true,
    showSequenceNumbers: false,
    sequenceNumberStart: 10,
    sequenceNumberIncrement: 5,
    separateWordsWithSpace: true,
    probeOffset: 0.068,
    probe: true, // Enable probing for floating head
    useZAxis: true, // Enable Z-axis output
    useG0: true,
    ihsRapid: 100,
    ihsSlow: 20,
    circleSlowdownRadius: 0.25,
    circleSlowdownPercentage: 50,
    airPressurePause: 2.0 // Air pressure pause in seconds
};

// user-defined properties
properties = {
    ihsToggle: true,
    thcToggle: true,
    pierceDelay: 0.5,
    pierceHeight: 0.15,
    cutHeight: 0.063,
    retractHeight: 1,
    ihsSpringback: 0.020,
    cutoffThickness: 0.5,
    pierceDelayFactor: 0.2,
    plungeFeedrate: 30, // Reduced plunge feedrate (IPM)
    markerToolEnabled: false, // Toggle for marker tool support
    markerPlungeHeight: 0.05, // Plunge height for marker tool
    markerFeedrate: 50 // Feedrate for marker tool
};

// user-defined property definitions
propertyDefinitions = {
    ihsToggle: {title:"IHS", description:"Toggles Initial Height Sensing ON or OFF", type:"boolean"},
    thcToggle: {title:"THC", description:"Toggles Auto Torch Height Control ON or OFF", type:"boolean"},
    pierceDelay: {title:"Pierce Delay (sec)", description:"Specifies the delay to pierce in seconds.", type:"number"},
    pierceHeight: {title:"Pierce Height (in)", description:"Height at which to pierce material.", type:"number"},
    cutHeight: {title:"Cut Height (in)", description:"Height at which to cut material.", type:"number"},
    retractHeight: {title:"Retract Height (in)", description:"Height at which to retract above material.", type:"number"},
    ihsSpringback: {title:"IHS Springback (in)", description:"Account for material springback in IHS switch.", type:"number"},
    cutoffThickness: {title:"THC Cutoff Thickness (in)", description:"Material thickness above which THC sensitivity is reduced.", type:"number"},
    pierceDelayFactor: {title:"Pierce Delay Factor (sec/0.1\")", description:"Additional pierce delay per 0.1\" of material thickness above baseline.", type:"number"},
    plungeFeedrate: {title:"Plunge Feedrate (IPM)", description:"Reduced feedrate for plunge moves to protect consumables.", type:"number"},
    markerToolEnabled: {title:"Marker Tool Enabled", description:"Toggle for marker tool support.", type:"boolean"},
    markerPlungeHeight: {title:"Marker Plunge Height (in)", description:"Plunge height for marker tool.", type:"number"},
    markerFeedrate: {title:"Marker Feedrate (IPM)", description:"Feedrate for marker tool.", type:"number"}
};

var gFormat = createFormat({prefix:"G", decimals:0});
var gFormatDeci = createFormat({prefix:"G", decimals:1});
var mFormat = createFormat({prefix:"M", decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4), forceDecimal:true});
var zFormat = createFormat({decimals:(unit == MM ? 3 : 4), forceDecimal:true});
var abcFormat = createFormat({decimals:3, forceDecimal:true, scale:DEG});
var secFormat = createFormat({decimals:3, forceDecimal:true});
var feedFormat = createFormat({decimals:(unit == MM ? 2 : 3), forceDecimal:true});

var xOutput = createVariable({prefix:"X"}, xyzFormat);
var yOutput = createVariable({prefix:"Y"}, xyzFormat);
var zOutput = createVariable({prefix:"Z"}, xyzFormat);

var aOutput = createVariable({prefix:"A"}, abcFormat);
var bOutput = createVariable({prefix:"B"}, abcFormat);
var cOutput = createVariable({prefix:"C"}, abcFormat);
var feedOutput = createVariable({prefix:"F"}, feedFormat);

// circular output
var iOutput = createReferenceVariable({prefix:"I", force:true}, xyzFormat);
var jOutput = createReferenceVariable({prefix:"J", force:true}, xyzFormat);
var kOutput = createReferenceVariable({prefix:"K", force:true}, xyzFormat);

var gMotionModal = createModal({force:true}, gFormat);
var gPlaneModal = createModal({onchange:function () {gMotionModal.reset();}}, gFormat);
var gAbsIncModal = createModal({}, gFormat);
var gFeedModeModal = createModal({}, gFormat);
var gUnitModal = createModal({}, gFormat);

// collected state
var sequenceNumber;
var initialG31 = false;

/**
 Writes the specified block.
 */
function writeBlock() {
    if (staticproperties.showSequenceNumbers) {
        writeWords2("N" + sequenceNumber, arguments);
        sequenceNumber += staticproperties.sequenceNumberIncrement;
    } else {
        writeWords(arguments);
    }
}

function formatComment(text) {
    return "(" + String(text).replace(/[()]/g, "") + ")";
}

/**
 Output a comment.
 */
function writeComment(text) {
    writeln(formatComment(text));
}

function onOpen() {
    receivedMachineConfiguration = machineConfiguration.isReceived();
    if (staticproperties.useZAxis) {
        zFormat.setOffset(staticproperties.probeOffset);
        zOutput = createVariable({prefix:"Z"}, zFormat);
    } else {
        zOutput.disable();
    }

    if (!staticproperties.separateWordsWithSpace) {
        setWordSeparator("");
    }

    sequenceNumber = staticproperties.sequenceNumberStart;
    writeComment("v1.6-af Enhanced");

    if (programComment) {
        writeComment(programComment);
    }

    // dump machine configuration
    var vendor = machineConfiguration.getVendor();
    var model = machineConfiguration.getModel();
    var description = machineConfiguration.getDescription();

    if (staticproperties.writeMachine && (vendor || model || description)) {
        writeComment(localize("Machine"));
        if (vendor) {
            writeComment("  " + localize("vendor") + ": " + vendor);
        }
        if (model) {
            writeComment("  " + localize("model") + ": " + model);
        }
        if (description) {
            writeComment("  " + localize("description") + ": "  + description);
        }
    }

    // absolute coordinates and feed per min
    writeBlock(gAbsIncModal.format(90), gFeedModeModal.format(94));
    writeBlock(gPlaneModal.format(17));

    switch (unit) {
        case IN:
            writeBlock(gUnitModal.format(20));
            break;
        case MM:
            writeBlock(gUnitModal.format(21));
            break;
    }

    // Force THC OFF
    writeln("H0");
}

function onComment(message) {
    writeComment(message);
}

/** Force output of X, Y, and Z. */
function forceXYZ() {
    xOutput.reset();
    yOutput.reset();
    zOutput.reset();
}

/** Force output of A, B, and C. */
function forceABC() {
    aOutput.reset();
    bOutput.reset();
    cOutput.reset();
}

/** Force output of X, Y, Z, A, B, C, and F on next output. */
function forceAny() {
    forceXYZ();
    forceABC();
}

function onParameter(name, value) {
}

var currentWorkPlaneABC = undefined;

function forceWorkPlane() {
    currentWorkPlaneABC = undefined;
}

var closestABC = false;
var currentMachineABC;

function getWorkPlaneMachineABC(workPlane) {
    var W = workPlane;
    var abc = machineConfiguration.getABC(W);
    if (closestABC) {
        if (currentMachineABC) {
            abc = machineConfiguration.remapToABC(abc, currentMachineABC);
        } else {
            abc = machineConfiguration.getPreferredABC(abc);
        }
    } else {
        abc = machineConfiguration.getPreferredABC(abc);
    }

    try {
        abc = machineConfiguration.remapABC(abc);
        currentMachineABC = abc;
    } catch (e) {
        error(
            localize("Machine angles not supported") + ":"
            + conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(abc.x))
            + conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(abc.y))
            + conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(abc.z))
        );
    }

    var direction = machineConfiguration.getDirection(abc);
    if (!isSameDirection(direction, W.forward)) {
        error(localize("Orientation not supported."));
        return new Vector();
    }

    if (!machineConfiguration.isABCSupported(abc)) {
        error(
            localize("Work plane is not supported") + ":"
            + conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(abc.x))
            + conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(abc.y))
            + conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(abc.z))
        );
    }

    var tcp = false;
    if (tcp) {
        setRotation(W);
    } else {
        var O = machineConfiguration.getOrientation(abc);
        var R = machineConfiguration.getRemainingOrientation(abc, W);
        setRotation(R);
    }

    return abc;
}

function onSection() {
    writeln("");
    if (hasParameter("operation-comment")) {
        var comment = getParameter("operation-comment");
        if (comment) {
            writeComment(comment);
        }
    }

    switch (tool.type) {
        case TOOL_PLASMA_CUTTER:
            break;
        case TOOL_MARKER:
            if (!properties.markerToolEnabled) {
                error(localize("Marker tool not enabled in post processor."));
                return;
            }
            break;
        default:
            error(localize("The CNC does not support the required tool/process."));
            return;
    }

    switch (currentSection.jetMode) {
        case JET_MODE_THROUGH:
            break;
        case JET_MODE_ETCHING:
            writeComment("ETCHING MODE ACTIVE");
            feedOutput.format(200);
            zOutput.format(0.15);
            break;
        case JET_MODE_VAPORIZE:
            error(localize("Vaporize cutting mode is not supported."));
            return;
        default:
            error(localize("Unsupported cutting mode."));
            return;
    }

    { // pure 3D
        var remaining = currentSection.workPlane;
        if (!isSameDirection(remaining.forward, new Vector(0, 0, 1))) {
            error(localize("Tool orientation is not supported."));
            return;
        }
        setRotation(remaining);
    }

    forceAny();

    var initialPosition = getFramePosition(currentSection.getInitialPosition());
    if (staticproperties.useG0) {
        writeBlock(gMotionModal.format(0), xOutput.format(initialPosition.x), yOutput.format(initialPosition.y));
    } else {
        writeBlock(gMotionModal.format(1), xOutput.format(initialPosition.x), yOutput.format(initialPosition.y), feedOutput.format(highFeedrate));
    }
    initialG31 = true;
    writeG31();

    if (staticproperties.useZAxis) {
        if (staticproperties.useG0) {
            writeBlock(gMotionModal.format(0), zOutput.format(initialPosition.z));
        } else {
            writeBlock(gMotionModal.format(1), zOutput.format(initialPosition.z), feedOutput.format(highFeedrate));
        }
    }
}

function onDwell(seconds) {
    if (seconds > 99999.999) {
        warning(localize("Dwelling time is out of range."));
    }
    seconds = clamp(0.001, seconds, 99999.999);
    writeBlock(gFormat.format(4), "P" + secFormat.format(seconds));
}

function onCycle() {
}

function getCommonCycle(x, y, z, r) {
}

function onCyclePoint(x, y, z) {
}

function onCycleEnd() {
}

var pendingRadiusCompensation = -1;

function onRadiusCompensation() {
    pendingRadiusCompensation = radiusCompensation;
}

function writeG31() {
    if (staticproperties.probe) {
        var f = (hasParameter("operation:tool_feedEntry") ? getParameter("operation:tool_feedEntry") : toPreciseUnit(1000, MM));
        writeBlock(gFormat.format(31), "Z" + xyzFormat.format(-100), feedOutput.format(f));
        writeBlock(gFormat.format(92), "Z" + xyzFormat.format(staticproperties.probeOffset));
        feedOutput.reset();
    }
}

var powerIsOn = false;
function onPower(power) {
    initialG31 = false;
    pierceCount++;

    if (powerIsOn !== power) {
        if (power) {
            //-------- BEFORE M3
            if (properties.ihsToggle) {
                writeBlock(gFormat.format(92), "Z" + xyzFormat.format(0));
                writeBlock(gFormatDeci.format(38.2), "Z" + xyzFormat.format(-5 * (unit == MM ? 25.4 : 1)), feedOutput.format(staticproperties.ihsRapid * (unit == MM ? 25.4 : 1)));
                writeBlock(gFormatDeci.format(38.4), "Z" + xyzFormat.format(0.5 * (unit == MM ? 25.4 : 1)), feedOutput.format(staticproperties.ihsSlow * (unit == MM ? 25.4 : 1)));
                writeBlock(gFormat.format(92), "Z" + xyzFormat.format(0));
                writeBlock(gFormat.format(0), "Z" + xyzFormat.format((properties.ihsSpringback + 0.02) * (unit == MM ? 25.4 : 1)), "(IHS Springback + Backlash)");
                writeBlock(gFormat.format(92), "Z" + xyzFormat.format(0));
                writeBlock(gFormat.format(0), "Z" + xyzFormat.format(properties.pierceHeight * (unit == MM ? 25.4 : 1)), "(Pierce Height)");
                feedOutput.reset();
            }

            // Air Pressure Pause
            if (staticproperties.airPressurePause > 0) {
                onDwell(staticproperties.airPressurePause);
            }

            // Calculate dynamic pierce delay
            var materialThickness = getMaterialThickness();
            var additionalDelay = 0;
            if (materialThickness > 0.5) {
                additionalDelay = (materialThickness - 0.5) * properties.pierceDelayFactor;
            }
            var dynamicPierceDelay = properties.pierceDelay + additionalDelay;
            onDwell(dynamicPierceDelay);

            // Feedrate-Limited Plunge
            if (properties.plungeFeedrate > 0) {
                feedOutput.format(properties.plungeFeedrate);
            }

            // Re-Home Z-axis if threshold reached
            if (pierceCount >= reHomeThreshold) {
                writeComment("Re-homing Z-axis");
                writeG31();
                pierceCount = 0;
            }
        } else {
            //--------  BEFORE M5
            if (properties.thcToggle) {
                writeln("H0");
            }
        }

        // M3 or M5
        writeBlock(mFormat.format(power ? 3 : 5));
        powerIsOn = power;

        if (power) {
            //---------- After M3
            // New Cut Height
            if (properties.ihsToggle) {
                writeBlock(gFormat.format(0), "Z" + xyzFormat.format((properties.cutHeight) * (unit == MM ? 25.4 : 1)), " (Cut Height)");
            }

            // THC Enable with sensitivity adjustment
            if (properties.thcToggle) {
                if (materialThickness > properties.cutoffThickness) {
                    writeln("H1 S0.5");
                } else {
                    writeln("H1");
                }
            }
        } else {
            //----------- After M5
            writeBlock(gFormat.format(0), "Z" + xyzFormat.format(properties.retractHeight * (unit == MM ? 25.4 : 1)));
            writeln("");
        }
    }
}

function onRapid(_x, _y, _z) {
    var x = xOutput.format(_x);
    var y = yOutput.format(_y);
    var z = zOutput.format(_z);
    if (!x && !y && z && (_z < getCurrentPosition().z) && !initialG31 && !powerIsOn) {
        writeG31();
    }
    if (x || y || z) {
        if (pendingRadiusCompensation >= 0) {
            error(localize("Radius compensation mode cannot be changed at rapid traversal."));
            return;
        }
        if (staticproperties.useG0) {
            writeBlock(gMotionModal.format(0), x, y, z);
        } else {
            writeBlock(gMotionModal.format(1), x, y, z, feedOutput.format(highFeedrate));
        }
        feedOutput.reset();
    }
}

function onLinear(_x, _y, _z, feed) {
    if (getMovement() == MOVEMENT_CUTTING && feed > maxCuttingFeedRate) {
        maxCuttingFeedRate = feed;
    }

    if (pendingRadiusCompensation >= 0) {
        xOutput.reset();
        yOutput.reset();
    }
    var x = xOutput.format(_x);
    var y = yOutput.format(_y);
    var z = zOutput.format(_z);
    var f = feedOutput.format(feed);

    if (!x && !y && z && (_z < getCurrentPosition().z) && !initialG31 && !powerIsOn) {
        writeG31();
    }
    if (x || y || (z && !powerIsOn)) {
        if (pendingRadiusCompensation >= 0) {
            pendingRadiusCompensation = -1;
            switch (radiusCompensation) {
                case RADIUS_COMPENSATION_LEFT:
                    writeBlock(gMotionModal.format(1), gFormat.format(41), x, y, z, f);
                    break;
                case RADIUS_COMPENSATION_RIGHT:
                    writeBlock(gMotionModal.format(1), gFormat.format(42), x, y, z, f);
                    break;
                default:
                    writeBlock(gMotionModal.format(1), gFormat.format(40), x, y, z, f);
            }
        } else {
            writeBlock(gMotionModal.format(1), x, y, z, f);
        }
    }
    if (firstLoop) {
        feedOutput.reset();
        firstLoop = false;
    }
}

function onRapid5D(_x, _y, _z, _a, _b, _c) {
    error(localize("The CNC does not support 5-axis simultaneous toolpath."));
}

function onLinear5D(_x, _y, _z, _a, _b, _c, feed) {
    error(localize("The CNC does not support 5-axis simultaneous toolpath."));
}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
    if (getMovement() == MOVEMENT_CUTTING && feed > maxCuttingFeedRate) {
        maxCuttingFeedRate = feed;
    }

    if (pendingRadiusCompensation >= 0) {
        error(localize("Radius compensation cannot be activated/deactivated for a circular move."));
        return;
    }

    var start = getCurrentPosition();
    if (getCircularRadius() < properties.circleSlowdownRadius) {
        feed = feed * (properties.circleSlowdownPercentage / 100);
    }

    if (isFullCircle()) {
        if (isHelical()) {
            linearize(tolerance);
            return;
        }
        switch (getCircularPlane()) {
            case PLANE_XY:
                writeBlock(gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
                break;
            default:
                linearize(tolerance);
        }
    } else {
        switch (getCircularPlane()) {
            case PLANE_XY:
                writeBlock(gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
                break;
            default:
                linearize(tolerance);
        }
    }
    if (firstLoop) {
        feedOutput.reset();
        firstLoop = false;
    }
}

var mapCommand = {
    COMMAND_STOP:0,
    COMMAND_OPTIONAL_STOP:1
};

function onCommand(command) {
    switch (command) {
        case COMMAND_POWER_ON:
            return;
        case COMMAND_POWER_OFF:
            return;
        case COMMAND_LOCK_MULTI_AXIS:
            return;
        case COMMAND_UNLOCK_MULTI_AXIS:
            return;
        case COMMAND_BREAK_CONTROL:
            return;
        case COMMAND_TOOL_MEASURE:
            return;
    }

    var stringId = getCommandStringId(command);
    var mcode = mapCommand[stringId];
    if (mcode != undefined) {
        writeBlock(mFormat.format(mcode));
    } else {
        onUnsupportedCommand(command);
    }
}

function onSectionEnd() {
    forceAny();
}

function onClose() {
    writeBlock(mFormat.format(30));
    writeComment("PS" + Math.floor(maxCuttingFeedRate));
}

function getMaterialThickness() {
    // Replace with actual logic to retrieve material thickness
    // Example: return a default value or fetch from a parameter
    return 0.75; // Default value (inches)
}
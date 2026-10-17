# Small issues for the Claude issue bot

Each section below is one issue: copy the `Title` line into the issue title and
everything under **Body** into the issue body. They are sized for one bot run
(one command or one component each) and point at the code to copy, so the bot
spends its time writing code rather than searching.

Suggested order: 1–4 first (cheapest, most useful), then the rest.
File them a few at a time and review each draft PR before filing more: every
issue starts a parallel run on the maintainer's subscription.

---

## 1. Add MirrorElements command

**Title:** Add MirrorElements command

**Body:**

Feature request: a `MirrorElements` command, the mirror counterpart of `MoveElements` / `RotateElements`.

- Input: `elementsWithMirrorAxis` — array of `{ elementId, begPoint {x,y}, endPoint {x,y}, copy (bool, optional, default false) }`.
- Response: execution results per element, like `MoveElements`.
- Implementation: copy `MoveElement`/`RotateElement` in `archicad-addon/Sources/ElementCommands.cpp` (~line 3701) and use `ACAPI_Element_Edit` with `editPars.typeID = APIEdit_Mirror`, `origC` = begPoint, `endC` = endPoint, `withDelete = !copy`. Run it inside `ACAPI_CallUndoableCommand` like the existing ones.
- Register it in `AddOnMain.cpp` next to `RotateElementsCommand` (Element group) with the version in `tools/package_info.json`.
- Add `archicad-addon/Examples/mirror_elements.py` following `move_elements.py`.
- Add the Grasshopper component `MirrorElementsComponent.cs` next to `RotateElementsComponent.cs` in `grasshopper-plugin/TapirGrasshopperPlugin/Components/ElementsComponents/`.

---

## 2. Add ElevateElements command

**Title:** Add ElevateElements command (vertical move)

**Body:**

Feature request: an `ElevateElements` command that moves elements vertically by a given offset, like Archicad's Edit > Move > Elevate.

- Input: `elementsWithElevation` — array of `{ elementId, elevation (number, meters), copy (bool, optional) }`.
- Implementation: same pattern as `MoveElement` in `archicad-addon/Sources/ElementCommands.cpp` (~line 3701), using `ACAPI_Element_Edit` with `APIEdit_Elevate` (`endC.z` = elevation), inside `ACAPI_CallUndoableCommand`.
- Register in `AddOnMain.cpp` next to `MoveElementsCommand`, version from `tools/package_info.json`.
- Add `archicad-addon/Examples/elevate_elements.py` and a Grasshopper component next to `MoveElementsComponent.cs`.

---

## 3. Grasshopper component for SetIFCPropertiesOfElements

**Title:** Grasshopper: add SetIFCPropertiesOfElements component

**Body:**

The add-on command `SetIFCPropertiesOfElements` (registered in `archicad-addon/Sources/AddOnMain.cpp` ~line 914) has no Grasshopper component, while `GetIFCPropertiesOfElements` does.

- Add `SetIFCPropertiesOfElementsComponent.cs` in `grasshopper-plugin/TapirGrasshopperPlugin/Components/IFCComponents/`, modeled on `GetIFCPropertiesOfElementsComponent.cs` and on `PropertiesComponents/SetPropertyValuesOfElementsComponent.cs` for the setter shape.
- Read the input schema from `IFCCommands.cpp` (`SetIFCPropertiesOfElementsCommand::GetInputParametersSchema`).
- Give it a unique component GUID and an icon like the existing ones.

---

## 4. Grasshopper components for Get/SetMarkerParametersOfElements

**Title:** Grasshopper: add Get/SetMarkerParametersOfElements components

**Body:**

The add-on commands `GetMarkerParametersOfElements` and `SetMarkerParametersOfElements` (registered in `archicad-addon/Sources/AddOnMain.cpp` ~line 426) have no Grasshopper components.

- Add `GetMarkerParametersComponent.cs` and `SetMarkerParametersComponent.cs` in `grasshopper-plugin/TapirGrasshopperPlugin/Components/ElementsComponents/`, modeled on `GetGDLParametersComponent.cs` / `SetGDLParametersComponent.cs` (the marker commands use the same parameter shape as the GDL ones; check `ElementGDLParameterCommands.cpp`).
- Unique component GUIDs, icons like the existing ones.

---

## 5. FilterElements: filter by layer, story and element type

**Title:** FilterElements: add layer, story and element type filters

**Body:**

`FilterElements` only accepts Archicad's flag filters (`IsEditable`, `OnActualFloor`, …), so scripts that need "all walls on story 2 on layer X" must fetch everything and filter client-side.

- Add optional inputs to `FilterElementsCommand` (`archicad-addon/Sources/ElementCommands.cpp`, ~line 181): `layerIndices` (array of int), `floorIndices` (array of int), `elementTypes` (array of the existing element type enum from `SchemaDefinitions.cpp`).
- An element passes when it matches all given criteria (each array is OR within itself). Read `elem.header.layer`, `elem.header.floorInd`, and the type via the existing helpers in `CommandBase`.
- Fully backward compatible: omitted inputs mean no filtering.
- Extend `archicad-addon/Examples/filter_elements.py` (or the existing filter example) and the Grasshopper `FilterElementsComponent.cs` with the new optional inputs.

---

## 6. Add ActivateLayerCombination command

**Title:** Add command to activate a layer combination

**Body:**

You can create layer combinations (`CreateLayerCombinations`) and list them (`GetLayerCombinations`) but cannot apply one to the current view.

- Add `ActivateLayerCombinationCommand` in `archicad-addon/Sources/AttributeCommands.cpp/.hpp`.
- Input: `attributeId` (the layer combination's attribute guid, same shape as other attribute commands).
- Implementation: `ACAPI_Attribute_Get` the `API_LayerCombID`, then apply it (`ACAPI_Environment` / `ACAPI_Navigator` layer-combination change call available in the DevKit — check `archicad-addon/Build/DevKits/AC29/Support` headers). Guard API differences per `AC_VERSION` as done elsewhere.
- Register in the Attribute group in `AddOnMain.cpp`, add an example and a Grasshopper component next to `SetLayerCombinationsComponent.cs`.

---

## 7. Add UpdateLayers command

**Title:** Add UpdateLayers command (rename, hide/show, lock/unlock)

**Body:**

Layers can only be created or deleted; there is no way to change an existing layer's name, visibility or lock state.

- Add `UpdateLayersCommand` in `archicad-addon/Sources/AttributeCommands.cpp/.hpp`.
- Input: `layerDataArray` — array of `{ attributeId, name?, isHidden?, isLocked?, isWireframe? }`; only provided fields change.
- Implementation: `ACAPI_Attribute_Get` → modify `API_Attribute.layer` / header flags → `ACAPI_Attribute_Modify`, inside `ACAPI_CallUndoableCommand`. Reuse the input field names of `CreateLayersCommand`.
- Register in the Attribute group in `AddOnMain.cpp`, add an example, and extend the Grasshopper `SetLayersComponent.cs` or add `UpdateLayersComponent.cs`.

---

## 8. Add ModifyZones command

**Title:** Add ModifyZones command

**Body:**

Zones can be created (`CreateZones`) but there is no `ModifyZones`, unlike walls, slabs, columns, etc.

- Add `ModifyZonesCommand` following `ModifySlabsCommand` (`archicad-addon/Sources/ExtendedElementCommands.cpp/.hpp`).
- Modifiable fields: `name`, `numberStr`, `categoryAttributeId`, `stampPosition`, `height` (match the field names `CreateZones` already uses).
- Register in `AddOnMain.cpp` next to `ModifySlabsCommand`, add `archicad-addon/Examples/modify_zones.py`, and a Grasshopper `ModifyZonesComponent.cs` next to `ModifySlabsComponent.cs`.

---

## 9. Add ModifyOpenings command

**Title:** Add ModifyOpenings command

**Body:**

Openings can be created (`CreateOpenings`) but not modified.

- Add `ModifyOpeningsCommand` following `ModifyWindowsCommand` (`archicad-addon/Sources/ExtendedElementCommands.cpp/.hpp`), modifying the same fields `CreateOpenings` accepts (width, height, extrusion geometry).
- Register next to `ModifyWindowsCommand` in `AddOnMain.cpp`, add an example and a Grasshopper component next to `ModifyWindowsComponent.cs`.

---

## 10. Add GetQuantitiesOfElements command

**Title:** Add GetQuantitiesOfElements command (area, volume, length)

**Body:**

There is no direct way to get element quantities; today you have to look up built-in property GUIDs and call `GetPropertyValuesOfElements`.

- Add `GetQuantitiesOfElementsCommand` in `archicad-addon/Sources/ElementCommands.cpp/.hpp`.
- Input: `elements` (element ids). Response per element: `area`, `volume`, `length` where meaningful for the type (walls, slabs, beams, columns, zones, roofs, meshes, morphs); omit fields that don't apply.
- Implementation: `ACAPI_Element_GetQuantities` with the per-type `API_ElementQuantity` fields.
- Register in the Element group in `AddOnMain.cpp`, add an example and a Grasshopper component.

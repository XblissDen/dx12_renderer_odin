# Hierarchy

Any placed entity can have a parent, and then moves, turns and scales with
it. A parent can have any number of children, and children can have their
own.

## Data

The scene (`src/scene.odin`) stores the link as one more component:
`parents[i]` with a `has_parent[i]` flag, like every other component. An
entity's **transform is relative to its parent**: position, rotation and scale
are in the parent's space, and a root's transform is in world space.

- **Who can be in a hierarchy**: entities with a transform, except the camera
  (it steers its own transform) and the sun (it has only a direction).
  `scene_parentable` checks this.
- **No cycles**: `scene_can_parent` refuses a parent that is the entity itself
  or one of its descendants. The editor, undo and loading all go through it
  or an equivalent check.
- **Dead links**: a link to a slot that is not alive counts as no parent. This
  only happens for a moment while a deleted subtree is being restored.
- **Empty entities**: an entity can have just a transform, with no mesh and
  no light. It groups its children and places them, like a glTF node without
  geometry. It is listed, selected and edited like any other entity, but it
  cannot be clicked in the viewport. Selecting it outlines its descendants,
  and Focus Selected frames them.

## glTF node trees

**Add Model** brings in a glTF model that has more than one node as its node
tree: an empty entity named after the model, three units in front of the
camera, with one child entity per node. Nodes with geometry draw their part;
nodes without geometry become empty entities. Clear **As its node tree**
beside the button to add the flattened model as one entity instead. That has
fewer draws, which is better for a large static model such as Sponza.

Every node entity's placement is in its parent's space, so moving, hiding
under a collapsed row, duplicating or deleting the group takes the whole
model along. The parts placed by their entities land exactly on the flattened
model's geometry, mirrored nodes included ([Assets](assets.md#gltf-node-trees)).
The whole model is added as one undo step. If the entity slots run out
partway, none of it is added.

## World matrices

`scene_world_matrix` places an entity in the world: its own transform matrix,
then its parent's, then the grandparent's, and so on up to the root. It is
computed when asked rather than cached, so it can never lag behind an edit
made earlier in the frame. The cost is one matrix product per ancestor, which
is small for a scene of 1024 entities with shallow trees.

Everything that needs to know where an entity is uses it:

- **Rendering**: each draw's model matrix, the previous frame's matrix for
  motion vectors, and the bounds for culling.
- **Lights**: point and spot light positions, the spot direction (the world
  matrix's −Y axis), and their shadow maps and shadow-slot distances.
- **Editor**: picking (the ray goes into the entity's space through the
  inverse world matrix), selection boxes, Focus Selected, and the gizmo.

Animation stays local. **Spin** turns an entity about its own Y axis, so a
spinning parent carries its children around. An orbiting point light circles
its **Orbit center** in its parent's space, so the whole orbit follows the
parent.

## Editing

**The entity list** in the Scene panel is a tree: children are indented under
their parent, and the arrow beside a parent hides or shows them. Drag a row
onto another to make it that row's child, or onto **(drop here to unparent)**
to make it a root. Dragging a selected entity moves the whole selection, or
rather its top entities: those with no selected ancestor, so that the rest
stay under them. Shift+click selects a range of rows as shown in the list.

**The Inspector's Parent picker** lists the entities the primary selection
can go under, plus (none).

**Reparenting keeps the world placement.** The entity's new local transform is
the inverse of the new parent's world matrix times the entity's world matrix,
split back into position, rotation and scale. An orbiting light's orbit center
moves into the new space the same way. The parent link and the transform
change together as one undo step: a `Parent` field edit plus the transform
fields.

**The gizmo** works in world space. Its handles sit at the primary's world
position, and local axes include the ancestors' rotation. Each entity the drag
moves converts the change into its parent's space:

- a move goes through the inverse of the parent's world matrix;
- a turn R about a world axis becomes P⁻¹·R·P in the parent's space (P is the
  parent's world matrix), applied to the local rotation.

When a parent and its child are both selected, only the parent moves and the
child follows it; otherwise the child would move twice. If the primary is the
child, its selected ancestor stays put.

**Duplicate Selected** copies each selected entity together with its
descendants. The top copy goes under the same parent, 1.5 world units along X
from its source, and the copied children go under the copy. **Delete
Selected** deletes the descendants too. Both are one undo step. Undoing a
delete restores the children before their parents, and their links come back
with them.

## Shear

A child that is rotated relative to a parent scaled unevenly (different
amounts per axis) ends up sheared in world space. Rendering, picking and
shadows multiply the matrices, so they show this exactly. A `Transform` can
only hold position, rotation and per-axis scale, though, so the editor keeps
the nearest fit in two places:

- reparenting such an entity, which can change its shape slightly;
- turning it with the gizmo, which keeps only the rotation part.

Uniform scales never shear. Unity behaves the same way.

## Scene files

From version 16, each saved entity can have a `parent`: the parent's position
in the file's entity list. Slots are compacted on save, so these are not
in-memory indices. Older files have no parents, and every entity loads as a
root. Loading rejects a parent out of range, an entity that cannot be in a
hierarchy, and cycles.

Undo steps that name a parent, whether as a reparent value or as a deleted
entity's snapshot, keep that slot from being reused while they are in the
history. This prevents an undo from linking to an unrelated new entity.

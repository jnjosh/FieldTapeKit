# ``FieldTapeKit/FieldDevice``

## Topics

### Finding an OP-1

- ``connections``
- ``ConnectionEvent``
- ``info``
- ``isConnected``
- ``id-swift.property``
- ``ID-swift.struct``

### Listing Tapes

- ``tapes()``
- ``tape(named:)``
- ``tapeSlots()``

### Taking Tapes Off

- ``copyTape(_:to:compression:progress:)``
- ``moveTape(_:to:progress:)``

### Putting Tapes Back

- ``restoreTape(from:as:conflict:progress:)``

### Making Tapes on the OP-1

- ``createTape(named:type:)``
- ``duplicateTape(_:as:progress:)``

### Deleting Tapes

- ``deleteTape(_:keeping:progress:)``
- ``prepareToDelete(_:)``
- ``deleteTape(_:)``

### The Album

- ``album()``
- ``copySide(_:to:progress:)``
- ``copyAlbum(to:progress:)``
- ``side(_:matches:)``
- ``restoreSide(_:from:conflict:progress:)``
- ``prepareToReplace(_:)``

### Listing Files

- ``contentsOfDirectory(at:)``
- ``item(at:)``
- ``fileExists(at:)``

### Reading Files

- ``contents(of:maximumSize:)``
- ``contents(of:range:)``
- ``copyItem(at:to:progress:)``

### Writing Files

- ``write(_:to:options:)``
- ``copyItem(at:to:options:progress:)``
- ``createDirectory(at:)``

### Deleting Files

- ``removeItem(at:keepingCopyAt:)``
- ``prepareToRemove(at:)``
- ``removeItem(_:)``

### Testing and Previews

- ``simulated(_:)``

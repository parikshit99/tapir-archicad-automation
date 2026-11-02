import aclib

# Activates the Wall tool in the Toolbox, then goes back to the Arrow tool.
# After the first call the next click on the floor plan starts a new wall.
aclib.RunTapirCommand ('SetActiveTool', {'elementType': 'Wall'})
aclib.RunTapirCommand ('SetActiveTool')

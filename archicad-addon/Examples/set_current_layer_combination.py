import aclib

# Applies the first layer combination to the current window, then restores
# the one that was active before (if the layers matched one).
previous = aclib.RunTapirCommand ('GetCurrentLayerCombination')
layerCombinations = aclib.RunTapirCommand ('GetAttributesByType', {'attributeType': 'LayerCombination'})['attributes']

if not layerCombinations:
    print ('The project has no layer combinations.')
else:
    first = layerCombinations[0]
    print ('Applying layer combination: ' + first['name'])
    aclib.RunTapirCommand ('SetCurrentLayerCombination', {'layerCombinationId': {'guid': first['attributeId']['guid']}})

    if 'layerCombinationId' in previous:
        aclib.RunTapirCommand ('SetCurrentLayerCombination', {'layerCombinationId': previous['layerCombinationId']})

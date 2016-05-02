function ConvertFrom-XmlPart($xml)
{
    $siblings = New-Object System.Collections.ArrayList

    foreach ($childNode in $xml.ChildNodes)
    {
        if ($childNode.NodeType -ne 'Text')
        {
            $sibling = ConvertFrom-XmlPart($childNode)

            $siblingNested = $null

            if ($sibling.GetType().Name -eq 'HashTable' -and $sibling.ContainsKey("Property"))
            {
                $siblingNested = $sibling["Property"]
            }
            else
            {
                $siblingNested = if ($sibling.Count -gt 0) { $sibling } else { $null }
            }

            $siblingInfo = New-Object PSObject -Property @{
                "ElementLocalName" = $childNode.Name
                "Sibling" = $siblingNested
            }

            $siblingCount = $siblings.Add($siblingInfo)
        }
        else
        {
            return $childNode.Value
        }
    }

    $siblingHash = @{}
    $siblingsGrouped = $siblings | Group-Object -Property ElementLocalName
    foreach ($siblingsGroup in $siblingsGrouped)
    {

        $siblingData = $siblingsGroup.Group | Select-Object -ExpandProperty Sibling
        $siblingHash.Add($siblingsGroup.Name, $siblingData)
    }

    return $siblingHash
}
 
function ConvertFrom-Xml($xml) 
{
    $hash = @{}
    $hash = ConvertFrom-XmlPart($xml)
    return New-Object PSObject -Property $hash
}
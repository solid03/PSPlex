function Get-PlexItem
{
	<#
		.SYNOPSIS
			Get a specific item.
		.DESCRIPTION
			Get a specific item.
		.PARAMETER Id
			The id of the item.
		.PARAMETER IncludeTracks
			Only valid for albums. If specified, the tracks in the album are returned.
		.PARAMETER LibraryTitle
			Gets all items from a library with the specified title.
		.PARAMETER Filter
			Specifies the query string that retrieves the items in the smart collection. The syntax matches the Plex Web GUI as closely as possible. Clauses are separated by a semi-colon ( ; ).

			Syntax:

			- <Atttribute> <Operator> <Value>
			- <Atttribute> <Operator> <Value>;<Atttribute> <Operator> <Value>

			- Attributes:
				- String
					- Title
					- Studio
					- Edition
				- Numeric
					- Rating
					- Year
					- Decade
					- Plays
				- Exact
					- ContentRating
					- Genre
					- Collection
					- Actor
					- Country
					- SubtitleLanguage
					- AudioLanguage
					- Label
				- Boolean
					- Unmatched
					- Duplicate
					- Unplayed
					- HDR
					- InProgress
					- Trash
				- Semi-Boolean
					- Resolution
				- Date
					- ReleaseDate
					- DateAdded
					- LastPlayed

			- Operators:
				- String
					- Contains
					- DoesNotContain
					- Is
					- IsNot
					- BeginsWith
					- EndsWith
				- Numeric
					- Is
					- IsNot
					- IsGreaterThan
					- IsLessThan
				- Exact
					- Is
					- IsNot
				- Boolean
					- IsTrue
					- IsFalse
				- Semi-Boolean
					- Is
				- Date
					- IsBefore (Value format: yyyy-mm-dd)
					- IsAfter (Value format: yyyy-mm-dd)
					- IsInTheLast
					- IsNotInTheLast

			- Examples:
				- "DateAdded IsNotInTheLast 2y; Unplayed IsTrue"
				- "Title BeginsWith Star Trek; Unplayed IsTrue"
				- "Actor Is Jim Carrey; Genre Is Comedy"

		.PARAMETER MatchType
			Specifies how filter clauses are matched.

			- MatchAll: Matches all clauses.
			- MatchAny: Matches any cluase.

		.EXAMPLE
			# Get a single item by Id:
			Get-PlexItem -Id 204
		.EXAMPLE
			# Get all items from the library called 'Films'.
			# NOTE: Not all data for an item is returned this way.
			$Items = Get-PlexItem -LibraryTitle Films
			# Get all data for the above items:
			$AllData = $Items | % { Get-PlexItem -Id $_.ratingKey }
	#>

	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true, ParameterSetName = 'Id')]
		[String]
		$Id,

		[Parameter(Mandatory = $false, ParameterSetName = 'Id')]
		[Switch]
		$IncludeTracks,

		[Parameter(Mandatory = $true, ParameterSetName = 'Library')]
		[String]
		$LibraryTitle,

		[Parameter(Mandatory = $false, ParameterSetName = 'Library')]
		[String]
		$Filter,

		[parameter(Mandatory = $false, ParameterSetName = 'Library')]
		[String]
		[ValidateSet("MatchAny", "MatchAll")]
		$MatchType = "MatchAll"
	)

	#############################################################################
	#Region Import Plex Configuration
	if (!$script:PlexConfigData)
	{
		try
		{
			Import-PlexConfiguration -WhatIf:$False
		}
		catch
		{
			throw $_
		}
	}
	#EndRegion

	#############################################################################
	#Region Construct Uri
	if ($Id)
	{
		$DataUri = Get-PlexAPIUri -RestEndpoint "library/metadata/$Id"
	}
	elseif ($LibraryTitle)
	{
		# Get the library to determine what type it is:
		$Library = Get-PlexLibrary | Where-Object { $_.title -eq $LibraryTitle }

		# If we were to support lookup of a library by Id we have to consider
		# that it returns with no TYPE attribute, so we couldn't construct params correctly.
		# or KEY (presented as librarySectionID).

		if (!$Library)
		{
			throw "No such library. Run Get-PlexLibrary to see a list."
		}
		else
		{
			if ($Library.key)
			{
				$Key = $Library.key
			}
			elseif ($Library.librarySectionID)
			{
				$Key = $Library.librarySectionID
			}
			else
			{
				throw "Unable to determine library key/id/sectionId"
			}
			if ($Filter)
			{
				$Query = "&{0}" -f (Resolve-PlexFilter -MatchType $MatchType -LibraryId $Key -Filter $Filter)
			}

			$Params = [Ordered]@{
				sort                        = "titleSort$Query"
				includeGuids                = 1
				includeConcerts             = 0
				includeExtras               = 0
				includeOnDeck               = 0
				includePopularLeaves        = 0
				includePreferences          = 0
				includeReviews              = 0
				includeChapters             = 0
				includeStations             = 0
				includeExternalMedia        = 0
				asyncAugmentMetadata        = 0
				asyncCheckFiles             = 0
				asyncRefreshAnalysis        = 0
				asyncRefreshLocalMediaAgent = 0
			}
			$DataUri = Get-PlexAPIUri -RestEndpoint "library/sections/$Key/all" -Params $Params
		}
	}
	else {}
	#EndRegion

	#############################################################################
	#Region Get data
	try
	{
		$Data = Invoke-RestMethod -Uri $DataUri -Method GET

		# The metadata returned from Plex often contains duplicate values which breaks the (inherent) conversion into JSON, ending up as a string. Known cases:
		# guid and Guid
		# rating and Rating
		# The uppercase versions seem to be arrays of richer data, e.g. Guid contains IDs from various other metadata sources, as does Rating.

		# This isn't always the case however, so we need to check the object type:
		if ($Data.gettype().Name -eq 'String')
		{
			# Let's go with renaming the lowercase keys. Using .Replace rather than -replace as it should be faster.
			$Data = $Data.toString().Replace('"guid"', '"_guid"').Replace('"rating"', '"_rating"')
			# Convert back into JSON:
			$Data = $Data | ConvertFrom-Json
		}
		else
		{
			# $Data should be JSON already.
		}

		# If this is an album, respect -IncludeTracks and get track data:
		if ($Data.MediaContainer.Metadata.type -eq 'album' -and $IncludeTracks)
		{
			Write-Verbose -Message "Function: $($MyInvocation.MyCommand): Making additional lookup for album tracks"
			# $Data returned above has a key property on albums which equals: /library/metadata/{ratingKey}/children
			$TrackURi = Get-PlexAPIUri -RestEndpoint $Data.MediaContainer.Metadata.key
			$ChildData = Invoke-RestMethod -Uri $TrackURi -Method GET
			# Append:
			$Data.MediaContainer.Metadata | Add-Member -MemberType NoteProperty -Name 'Tracks' -Value $ChildData.MediaContainer.Metadata
		}

		# Return the required subproperty:
		return $Data.MediaContainer.Metadata
	}
	catch
	{
		throw $_
	}
	#EndRegion
}
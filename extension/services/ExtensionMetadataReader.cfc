component accessors=true {

	property name="s3root"            type="string" default="";
	property name="extensionMeta"     type="query";
	property name="extensionVersions" type="struct";

	variables._simpleCache = {};

	function loadMeta() {
		var meta           = _readExistingMetaFileFromS3();
		var existingByFile = _mapExtensionQueryByFilename( meta );
		var lexFiles       = _listLexFilesFromBucket();
		var metaChanged    = false;

		for( var lexFile in lexFiles ) {
			var isNewToUs = !StructKeyExists( existingByFile, lexFile.name )
			if ( isNewToUs ) {
				_addLexFile( lexFile.name, meta );
				metaChanged = true;
			}
		}
		if ( metaChanged ) {
			QuerySort( meta, "name,id,versionSortable", "asc,asc,desc" );
			_writeMetaFileToS3( meta );
		}

		setExtensionMeta( meta );
		_createExtensionAndVersionMap();

		// todo, convert all this to individual extension structs + individual version structs ready to roll


		return meta;
	}

	public function list(
		  required string  type     = "all"
		,          boolean flush    = false
		,          boolean withLogo = false
		,          boolean all      = false
	) {
		var cacheKey = "list-" & ( arguments.withLogo ? "wl" : "nl" ) & "_" & arguments.type & ( arguments.all ? "_all" : "" );

		if ( arguments.flush || !StructKeyExists( variables._simpleCache, cacheKey ) ) {
			if ( !IsQuery( variables.extensionMeta ?: "" ) || arguments.flush ) {
				loadMeta();
			}

			var extensions = Duplicate( getExtensionMeta() );

			if ( arguments.type != "all" ) {
				_filterExtensionTypes( extensions, arguments.type );
			}
			if ( !arguments.withLogo ) {
				_stripExtensionLogos( extensions );
			}
			if ( !arguments.all ) {
				extensions = _stripAllButLatestVersions( extensions );
			}

			variables._simpleCache[ cacheKey ] = extensions;
		}

		return variables._simpleCache[ cacheKey ];
	}

	public function getExtensionDetail(
		  required string  id
		,          string  version  = "latest"
		,          boolean flush    = false
		,          boolean withLogo = false
	) {
		if ( !IsQuery( variables.extensionMeta ?: "" ) || arguments.flush ) {
			loadMeta();
		}

		var mapped = getExtensionVersions();

		if ( StructKeyExists( mapped, arguments.id ) ) {
			if ( arguments.version == "latest" || isEmpty( arguments.version ) ) {
				arguments.version = mapped[ arguments.id ]._latest;
			}
			if ( StructKeyExists( mapped[ arguments.id ], arguments.version ) ) {
				var ext = StructCopy( mapped[ arguments.id ][ arguments.version ] );
				if ( !arguments.withLogo ) {
					ext.image = "";
				}
				return ext;
			}
		}

		return {};
	}

// PRIVATE HELPERS
	private function _listLexFilesFromBucket() {
		return DirectoryList(
			  path     = getS3Root()
			, sort     = "name"
			, listInfo = "query"
			, filter   = "*.lex"
		);
	}

	private function _readExistingMetaFileFromS3() {
		var metaFile = getS3Root() & "/extensions.json";
		if ( FileExists( metaFile  ) ) {
			return DeserializeJson( FileRead( metaFile ), false );
		}

		return _getEmptyExtensionsQuery();
	}

	private function _writeMetaFileToS3( meta ) {
		var metaFile = getS3Root() & "/extensions.json";

		FileWrite( metaFile, SerializeJson( meta ) );
	}

	private function _getEmptyExtensionsQuery() {
		return QueryNew( "id,version,versionSortable,name,description,filename,image,category,author,created,releaseType,minLoaderVersion,minCoreVersion,price,currency,disableFull,trial,older,olderName,olderDate,promotionLevel,promotionText,projectUrl,sourceUrl,documentionUrl" );
	}

	private function _mapExtensionQueryByFilename( extensionQuery ) {
		var mapped = {};

		for( var e in arguments.extensionQuery ) {
			mapped[ e.filename ] = e;
		}

		return mapped;
	}

	private function _addLexFile( fileName, extensionMetaQuery ) {
		SystemOutput( "Loading new extension file [#arguments.fileName#] from S3.", true );

		try {
			var tmpFile  = _copyRemoteFileToTmpFile( arguments.fileName );
			var qryCols  = ListToArray( arguments.extensionMetaQuery.columnList );
			var extMeta  = _initExtensionMetaFromManifest( tmpFile, qryCols );

			extMeta.filename        = arguments.fileName;
			extMeta.versionSortable = Len( extMeta.version ) ? Util::sortableVersionString( extMeta.version ) : "";
			extMeta.trial           = false; // "TODO"???
			extMeta.releaseType     = Len( extMeta.releaseType ) ? extMeta.releaseType : "all";
			extMeta.image           = _getLogoThumbnail( tmpFile );

			QueryAddRow( arguments.extensionMetaQuery, extMeta );

			_processExtensionJars( tmpFile );

			try {
				FileDelete( tmpFile );
			} catch( any e ) {
				SystemOutput( e, true );
			}
		} catch( any e ) {
			// for now, just to get through them all!
			SystemOutput( "Error processing lex file: [#arguments.fileName#]", true );
		}
	}

	private function _readLexManifest( filePath ) {
		try {
			var mf = ManifestRead( arguments.filePath );
		} catch( any e ) {}

		return mf.main ?: {};
	}

	private function _copyRemoteFileToTmpFile( fileName ) {
		var remoteFile = getS3Root() & "/" & arguments.fileName;
		var tmpFile = GetTempDirectory() & "/" & arguments.fileName;

		FileCopy( remoteFile, tmpFile );
		return tmpFile;
	}

	private function _initExtensionMetaFromManifest( lexFile, cols ) {
		var mf             = _readLexManifest( arguments.lexFile );
		var meta           = {};
		var commonMappings = {
			  created          = "Built-Date"
			, minCoreVersion   = "lucee-core-version"
			, minLoaderVersion = "lucee-loader-version"
			, releaseType      = "release-type"
		};

		for( var col in arguments.cols ) {
			meta[ col ] = mf[ col ] ?: "";
		}

		for( var mapping in commonMappings ) {
			if ( !Len( meta[ mapping ] ?: "" ) && Len( mf[ commonMappings[ mapping ] ] ?: "" ) ) {
				meta[ mapping ] = mf[ commonMappings[ mapping ] ]
			}
		}

		return meta;

	}

	private function _getLogoThumbnail( lexFile ){
		var zippedPath = "zip://" & arguments.lexFile & "!/META-INF/logo.png";
		var logoBase64 = "";

		if( FileExists( zippedPath ) ) {
			// reduce colour depth to 8 bit by writing to gif
			var tmpLogo     = ImageRead( zippedPath );
			var tmpGifThumb = GetTempFile( GetTempDirectory(), "logo") & ".gif";

			ImageWrite( ImageRead( zippedPath ), tmpGifThumb );

			logoBase64 = ToBase64( FileReadBinary( tmpGifThumb ) );

			try {
				FileDelete( tmpGifThumb );
			} catch( e ) {
				SystemOutput( e, true ); // ignore file locking
			}
		}

		return logoBase64;
	}

	private function _createExtensionAndVersionMap() {
		var raw = getExtensionMeta();
		var mapped = {};
		for( var extAndVersion in raw ) {
			mapped[ extAndVersion.id ] = mapped[ extAndVersion.id ] ?: { _latest=extAndVersion.version };
			mapped[ extAndVersion.id ][ extAndVersion.version ] = extAndVersion;
		}

		setExtensionVersions( mapped );
	}

	private function _processExtensionJars( lexFile ){
		// TODO!
		// var lexFileJarsDir = "zip://" & arguments.lexFile & "!jars/";

		// if ( DirectoryExists( lexFileJarsDir )) {
		// 	for( var jarPath in DirectoryList( path=lexFileJarsDir, listInfo="path", filter="*.jar" ) ) {
		// 		_processExtensionJar( jarPath );
		// 	}
		// }
	}

	private function _processExtensionJar( jarPath ) {

	}

	private function _filterExtensionTypes( extensions, type ) {
		for( var i=arguments.extensions.recordcount; i>=1; i-- ) {
			switch( arguments.type ) {
				case "snapshot":
					if( !FindNoCase( '-SNAPSHOT', arguments.extensions.version[ i ] ) ) {
						QueryDeleteRow( arguments.extensions, i );
					}
				break;
				case "abc":
					if(    !FindNoCase( '-ALPHA', arguments.extensions.version[ i ] )
						&& !FindNoCase( '-BETA' , arguments.extensions.version[ i ] )
						&& !FindNoCase( '-RC'   , arguments.extensions.version[ i ] )
					) {
						QueryDeleteRow( arguments.extensions, i );
					}
				break;
				case "release":
					if(    FindNoCase( '-ALPHA'   , arguments.extensions.version[ i ] )
						|| FindNoCase( '-BETA'    , arguments.extensions.version[ i ] )
						|| FindNoCase( '-RC'      , arguments.extensions.version[ i ] )
						|| FindNoCase( '-SNAPSHOT', arguments.extensions.version[ i ] )
					) {
						QueryDeleteRow( arguments.extensions, i );
					}
				break;
			}
		}
	}

	private function _stripExtensionLogos( extensions, type ) {
		for ( var i=arguments.extensions.recordcount; i >= 1; i-- ) {
			arguments.extensions.image[ i ] = "";
		}
	}

	private function _stripAllButLatestVersions( extensions ) {
		var last      = "";
		var collist   = QueryColumnList( arguments.extensions );
		var stripped  = QueryNew( collist );
		var older     = [];
		var olderName = [];
		var olderDate = [];

		for( var ext in arguments.extensions ) {
			if ( last != ext.id ) {
				var strippedCount = QueryRecordcount( stripped );
				if( strippedCount > 0 ) {
					QuerySetCell( stripped, "older"    , older    , strippedCount );
					QuerySetCell( stripped, "olderName", olderName, strippedCount );
					QuerySetCell( stripped, "olderDate", olderDate, strippedCount );

					older     = [];
					olderName = [];
					olderDate = [];
				}

				QueryAddrow( stripped, ext );
			} else if ( Len( ext.version ) ) {
				ArrayAppend( older    , ext.version  );
				ArrayAppend( olderName, ext.filename );
				ArrayAppend( olderDate, ext.created  );
			}

			last=ext.id;
		}

		var strippedCount = QueryRecordcount( stripped );
		if ( strippedCount && ArrayLen( older ) ) {
			QuerySetCell( stripped, "older"    , older    , strippedCount );
			QuerySetCell( stripped, "olderName", olderName, strippedCount );
			QuerySetCell( stripped, "olderDate", olderDate, strippedCount );
		}

		return stripped;
	}
}
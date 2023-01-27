component extends="org.lucee.cfml.test.LuceeTestCase" labels="data-provider" {

	function beforeAll(){
		variables.root = getDirectoryFromPath(getCurrentTemplatePath());  
		variables.root = listDeleteAt(root,listLen(root,"/\"), "/\") & "/";  // getDirectoryFromPath 
	};

	function run( testResults , testBox ) {
		describe( "Syntax check", function() {

			it(title="compile all update CFML/CFC files in CFML", body=function(){
				
				admin action="updateMapping"
					type="server"
					password=request.SERVERADMINPASSWORD
					virtual="/tmpUpdate"
					physical=variables.root & "update"
					archive=""
					primary="resource";

				expect( len( directoryList("/tmpUpdate") ) ).toBeGT( 0 );

				admin action="compileMapping"
					type="server"
					password=request.SERVERADMINPASSWORD
					virtual="/tmpUpdate"
					stoponerror="true";

			});

			it(title="compile all extension CFML/CFC files in CFML", body=function(){
				
				admin action="updateMapping"
					type="server"
					password=request.SERVERADMINPASSWORD
					virtual="/tmpExtension"
					physical=variables.root & "extension"
					archive=""
					primary="resource";
			
				expect( len( directoryList("/tmpExtension") ) ).toBeGT( 0 );

				admin action="compileMapping"
					type="server"
					password=request.SERVERADMINPASSWORD
					virtual="/tmpExtension"
					stoponerror="true";

			});

			it(title="compile all download CFML/CFC files in CFML", body=function(){
				
				admin action="updateMapping"
					type="server"
					password=request.SERVERADMINPASSWORD
					virtual="/tmpDownload"
					physical=variables.root & "download"
					archive=""
					primary="resource";
				
				expect( len( directoryList("/tmpDownload") ) ).toBeGT( 0 );

				admin action="compileMapping"
					type="server"
					password=request.SERVERADMINPASSWORD
					virtual="/tmpDownload"
					stoponerror="true";

			});
		});
	}
}

var PhyloWidget = {
	/**
	 * Opens a popup window containing PhyloWidget.
	 * Successive calls to this method will replace any existing PW popups (unless you specify the replace parameter to be false)
	 * The 'version' parameter should either be 'full' or 'lite'. 
	 */
  baseURL: 'http://www.phylowidget.org/ensembl/',
	 
 openPopup: function(version,params,noreplace)
 {
 	if (!version)
 		var version = 'lite';
 	var url = PhyloWidget.baseURL+version+'/bare.html?';
 	if (!params)
 		var params = {width:500,height:500};
 	url += PhyloWidget.getParamString(params);
	var width = params.width || 500;
	var height = params.height || 500;
	var targetString = 'PW';
	if (noreplace)
		targetString = '_blank';
	window.open(url,targetString,'height='+height+',width='+width+",menubar=no,toolbar=no,location=yes");
 },
 /**
  * Turns a hashtable of parameters into a URL query string ('&'-delimited)
  */
 getParamString: function(params)
 {
	var string = '';
	for (var key in params)
	{
		string += key + "=";
		string += params[key] + "&";
	}
	return string;
 }
};
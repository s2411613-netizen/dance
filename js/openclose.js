// Template-Party openclose.js
function OCwindowWidth() {
	if (window.innerWidth) {
		return window.innerWidth;
	} else if (document.documentElement && document.documentElement.clientWidth !== 0) {
		return document.documentElement.clientWidth;
	} else if (document.body) {
		return document.body.clientWidth;
	}
	return 0;
}

function open_close(btnId, targetId) {
	var btn = document.getElementById(btnId);
	var target = document.getElementById(targetId);
	if (!btn || !target) return;

	btn.addEventListener("click", function() {
		if (btn.className.indexOf("close") !== -1) {
			btn.className = btn.className.replace("close", "open");
			target.style.display = "block";
		} else {
			btn.className = btn.className.replace("open", "close");
			target.style.display = "none";
		}
	});
}

/// Sanitized output of `launchctl print gui/501` (labels replaced). A Swift file, not a resource, so the test
/// target needs no resource declaration.
enum LaunchctlPrintSample {
    static let text = #"""
gui/501 = {
	type = login
	handle = 501
	active count = 8
	service count = 5
	active service count = 3
	on-demand-only service count = 0

	endpoints = {
		"com.example.sanitized.endpoint" = {
			port = 0x1a03
			active = 1
		}
	}

	services = {
		   PID    Status  Label
		   612         0  com.example.running
		     -         0  com.example.idle
		     -       78  com.adkqa.broken
		 55120         0  application.com.example.App.1234.5678
		     -         0  homebrew.mxcl.adkqa
	}

	disabled services = {
		"com.example.off" => disabled
	}
}
"""#
}

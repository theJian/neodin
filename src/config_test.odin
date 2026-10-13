package main

import "core:encoding/json"
import "core:testing"

@(test)
test_config_defaults_and_validation :: proc(t: ^testing.T) {
	c := config_default()
	// JSON uses the standard library; omitted fields retain the defaults.
	testing.expect(t, json.unmarshal_string(`{"font_size":20,"renderer":"metal"}`, &c, allocator=context.temp_allocator) == nil)
	testing.expect(t, c.font_size == 20 && c.columns == 100 && c.vsync)
	testing.expect(t, config_validate(c) == "")
	c.font_size = 0
	testing.expect(t, config_validate(c) != "")
	c = config_default(); c.renderer = "software"
	testing.expect(t, config_validate(c) != "")
}

This is my bar script for
[sdorfehs](https://github.com/jcs/sdorfehs).

![Screenshot](https://jcs.org/images/sdorfehs-bar.png)

### Usage

Checkout somewhere, add local overrides to `~/.config/sdorfehs/bar-config.rb`
such as:

	config[:weather_api_key] = "your-api-key-here"

Add to the end of `~/.config/sdorfehs/config`:

	exec ruby ~/path/to/sdorfehs-bar.rb

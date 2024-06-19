# sdorfehs-bar

This is my bar script for
[sdorfehs](https://github.com/jcs/sdorfehs).

![Screenshot](https://jcs.org/images/sdorfehs-bar.png)

### Usage

Checkout somewhere, add local overrides to `~/.config/sdorfehs/bar-config.rb`
such as:

	config[:weather_api_key] = "your-api-key-here"

Install

	gem install ffi
 
[i3status](https://i3wm.org/i3status/)
and
[configure it](https://github.com/jcs/dotfiles/blob/master/.i3status.conf).

Add to the end of `~/.config/sdorfehs/config`:

	exec ruby ~/path/to/sdorfehs-bar.rb

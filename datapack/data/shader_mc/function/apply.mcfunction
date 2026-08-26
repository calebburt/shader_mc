# Post effects live in the player's saved data, so this only has to run once per
# player per world -- the advancement that calls it never fires again. Order is
# the order they are applied in: reflections first, then bloom over them, then
# depth of field last so it blurs the finished image.
posteffect add @s minecraft:ssr
posteffect add @s minecraft:bloom
posteffect add @s minecraft:dof

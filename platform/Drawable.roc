interface Drawable
    exposes [
        Drawable, 
        draw,
    ]
    imports [Task.{Task}]

Drawable implements
    draw : val -> Task {} [] where val implements Drawable

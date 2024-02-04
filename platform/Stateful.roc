interface Stateful
    exposes [
        Stateful,
        render,
        translate,
    ]
    imports [Task.{Task}]

Stateful implements
    render : Task model [], val -> Task model [] where val implements Stateful
    translate : child, (p -> c), (p, c -> p) -> parent where child implements Stateful

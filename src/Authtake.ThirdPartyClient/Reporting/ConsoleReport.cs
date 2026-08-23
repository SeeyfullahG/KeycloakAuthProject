namespace Authtake.ThirdPartyClient.Reporting;

/// <summary>
/// Konsol ciktisini okunakli tutan kucuk yardimci. Ayrica basarili/basarisiz
/// kontrolleri sayar; surec sonunda cikis kodunu buna gore veriyoruz ki bu
/// uygulama otomatik testlerden de calistirilabilsin.
/// </summary>
public sealed class ConsoleReport
{
    public int Passed { get; private set; }
    public int Failed { get; private set; }

    public void Title(string text)
    {
        Console.WriteLine();
        Write($"=== {text} ===", ConsoleColor.Cyan);
    }

    public void Step(string text)
    {
        Console.WriteLine();
        Write($"--- {text}", ConsoleColor.White);
    }

    public void Info(string label, string? value) =>
        Console.WriteLine($"    {label,-26}: {value ?? "-"}");

    public void Detail(string text) =>
        Write($"    {text}", ConsoleColor.DarkGray);

    /// <summary>Beklenen bir davranisi dogrular ve sonucu yazar.</summary>
    public bool Check(bool condition, string description)
    {
        if (condition)
        {
            Passed++;
            Write($"  [OK]   {description}", ConsoleColor.Green);
        }
        else
        {
            Failed++;
            Write($"  [FAIL] {description}", ConsoleColor.Red);
        }

        return condition;
    }

    public void Error(string text) => Write($"  [HATA] {text}", ConsoleColor.Red);

    public void Body(string text)
    {
        foreach (var line in text.Split('\n'))
            Write("      " + line.TrimEnd('\r'), ConsoleColor.DarkGray);
    }

    public int Summary()
    {
        Console.WriteLine();
        Write($"{Passed} basarili, {Failed} basarisiz.",
            Failed == 0 ? ConsoleColor.Green : ConsoleColor.Red);
        Console.WriteLine();
        return Failed == 0 ? 0 : 1;
    }

    private static void Write(string text, ConsoleColor color)
    {
        var previous = Console.ForegroundColor;
        Console.ForegroundColor = color;
        Console.WriteLine(text);
        Console.ForegroundColor = previous;
    }
}
